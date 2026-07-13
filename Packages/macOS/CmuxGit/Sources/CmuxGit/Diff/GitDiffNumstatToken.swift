struct GitDiffNumstatToken {
    let path: String
    let oldPath: String?
    let additions: Int?
    let deletions: Int?

    init?(token: String?, tokens: [String?], index: inout Int) {
        guard let token else { return nil }
        let pieces = token.split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard pieces.count == 3 else { return nil }
        additions = Int(pieces[0])
        deletions = Int(pieces[1])
        if pieces[2].isEmpty {
            guard index + 2 < tokens.count,
                  let decodedOldPath = tokens[index + 1],
                  let decodedPath = tokens[index + 2] else { return nil }
            oldPath = decodedOldPath
            path = decodedPath
            index += 3
        } else {
            oldPath = nil
            path = pieces[2]
            index += 1
        }
    }
}
