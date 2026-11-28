/// Many candidates, each with weighted fields, stored in flat arrays so a
/// search scan touches contiguous memory and does no reference counting.
///
/// Build it once when the candidate set changes; `matches` is then a
/// read-only scan. The first field of each candidate is its primary text
/// (title): only fields with weight 100 feed the length tie-breaker.
nonisolated public struct FuzzyCorpus: Sendable {
    private var scalars = ContiguousArray<UInt32>()
    private var bonuses = ContiguousArray<Int32>()
    private var initials = ContiguousArray<UInt32>()

    // Per field.
    private var fieldStart = ContiguousArray<Int>()
    private var fieldLength = ContiguousArray<Int>()
    private var initialsStart = ContiguousArray<Int>()
    private var initialsLength = ContiguousArray<Int>()
    private var fieldWeight = ContiguousArray<Int32>()
    private var fieldMask = ContiguousArray<UInt64>()

    // Per candidate.
    private var firstField = ContiguousArray<Int>()
    private var fieldCount = ContiguousArray<Int>()
    private var candidateMask = ContiguousArray<UInt64>()

    public init() {}

    public var count: Int { firstField.count }

    /// Adds a candidate. Returns its index.
    @discardableResult
    public mutating func append(_ fields: [FuzzyField]) -> Int {
        firstField.append(fieldStart.count)
        fieldCount.append(fields.count)
        var mask: UInt64 = 0
        for field in fields {
            let text = field.text
            fieldStart.append(scalars.count)
            fieldLength.append(text.folded.count)
            initialsStart.append(initials.count)
            initialsLength.append(text.initials.count)
            fieldWeight.append(field.weight)
            fieldMask.append(text.mask)
            scalars.append(contentsOf: text.folded)
            bonuses.append(contentsOf: text.bonus)
            initials.append(contentsOf: text.initials)
            mask |= text.mask
        }
        candidateMask.append(mask)
        return firstField.count - 1
    }

    /// Scores `candidates` (indices into this corpus) against `query`, in
    /// the given order. Candidates that do not match are omitted.
    public func matches(_ query: FuzzyQuery, in candidates: some Sequence<Int>) -> [(index: Int, score: Int)] {
        guard !query.isEmpty else { return candidates.map { ($0, 0) } }
        var result: [(index: Int, score: Int)] = []
        let queryMask = query.mask
        scalars.withUnsafeBufferPointer { s in
            bonuses.withUnsafeBufferPointer { b in
                initials.withUnsafeBufferPointer { i in
                    query.flat.withUnsafeBufferPointer { q in
                        query.phrase.withUnsafeBufferPointer { p in
                            query.joined.withUnsafeBufferPointer { j in
                                for candidate in candidates where candidateMask[candidate] & queryMask == queryMask {
                                    if let score = score(candidate, query, s, b, i, q, p, j) {
                                        result.append((candidate, Int(score)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    private func score(
        _ candidate: Int,
        _ query: FuzzyQuery,
        _ s: UnsafeBufferPointer<UInt32>,
        _ b: UnsafeBufferPointer<Int32>,
        _ i: UnsafeBufferPointer<UInt32>,
        _ q: UnsafeBufferPointer<UInt32>,
        _ p: UnsafeBufferPointer<UInt32>,
        _ j: UnsafeBufferPointer<UInt32>
    ) -> Int32? {
        let fields = firstField[candidate]..<(firstField[candidate] + fieldCount[candidate])
        var total: Int32 = 0
        for (tokenIndex, range) in query.ranges.enumerated() {
            let token = UnsafeBufferPointer(rebasing: q[range])
            let tokenMask = query.tokenMasks[tokenIndex]
            var best: Int32 = .min
            for field in fields where fieldMask[field] & tokenMask == tokenMask {
                let span = fieldStart[field]..<(fieldStart[field] + fieldLength[field])
                guard let match = FuzzyMatcher.tokenScore(
                    token,
                    UnsafeBufferPointer(rebasing: s[span]),
                    UnsafeBufferPointer(rebasing: b[span])
                ) else { continue }
                let weighted = match.score * fieldWeight[field] / 100
                if weighted > best { best = weighted }
            }
            guard best != .min else { return nil }
            total += best
        }
        var bonus: Int32 = 0
        var shortest = Int.max
        for field in fields {
            if fieldMask[field] & query.mask == query.mask {
                let span = fieldStart[field]..<(fieldStart[field] + fieldLength[field])
                let initialsSpan = initialsStart[field]..<(initialsStart[field] + initialsLength[field])
                let fieldBonus = FuzzyMatcher.phraseBonus(
                    phrase: p,
                    joined: j,
                    folded: UnsafeBufferPointer(rebasing: s[span]),
                    bonus: UnsafeBufferPointer(rebasing: b[span]),
                    initials: UnsafeBufferPointer(rebasing: i[initialsSpan])
                ) * fieldWeight[field] / 100
                if fieldBonus > bonus { bonus = fieldBonus }
            }
            if fieldWeight[field] == 100 { shortest = min(shortest, fieldLength[field]) }
        }
        // Shorter primary text wins ties ("Close Tab" over "Close Tabs to the Right").
        let lengthPenalty = shortest == .max ? 0 : Int32(shortest / 6)
        return total + bonus - lengthPenalty
    }

    /// Scalar offsets in field `field` of `candidate` that `query` matched,
    /// for highlighting. Empty when the query does not match that field.
    public func matchedPositions(_ query: FuzzyQuery, candidate: Int, field: Int = 0) -> [Int] {
        guard candidate < count, field < fieldCount[candidate] else { return [] }
        let index = firstField[candidate] + field
        let span = fieldStart[index]..<(fieldStart[index] + fieldLength[index])
        return scalars.withUnsafeBufferPointer { s in
            bonuses.withUnsafeBufferPointer { b in
                let folded = UnsafeBufferPointer(rebasing: s[span])
                let bonus = UnsafeBufferPointer(rebasing: b[span])
                let phraseStart: Int? = query.phrase.withUnsafeBufferPointer {
                    FuzzyMatcher.substringStart($0, folded, bonus, requireBoundary: false)
                }
                if let phraseStart {
                    return (phraseStart..<(phraseStart + query.phrase.count)).filter { folded[$0] != 0x20 }
                }
                var positions = Set<Int>()
                query.flat.withUnsafeBufferPointer { q in
                    for range in query.ranges {
                        let token = UnsafeBufferPointer(rebasing: q[range])
                        guard let match = FuzzyMatcher.tokenScore(token, folded, bonus) else { continue }
                        var ti = 0
                        for position in match.start...match.end where ti < token.count && folded[position] == token[ti] {
                            positions.insert(position)
                            ti += 1
                        }
                    }
                }
                return positions.sorted()
            }
        }
    }
}
