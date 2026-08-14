import Foundation

extension MobileTaskDirectorySearchService {
    nonisolated static func hasFuzzyComponent(_ query: String, in components: [String]) -> Bool {
        guard query.count >= 3 else { return false }
        let maximum = query.count >= 7 ? 2 : 1
        return components.contains { component in
            abs(component.count - query.count) <= maximum
                && editDistance(component, query, maximum: maximum) <= maximum
        }
    }

    private nonisolated static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= maximum else { return maximum + 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let value = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            previous = current
        }
        return previous.last ?? maximum + 1
    }
}
