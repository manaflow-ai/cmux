import Foundation

extension ArtifactByteReader {
    /// Retains the lexicographically smallest bounded set of directory names.
    /// A max-heap keeps each replacement at O(log capacity) instead of scanning
    /// every retained name for every entry in a large directory.
    struct DirectoryNameMaxHeap {
        let capacity: Int
        var values: [String] = []
        var didExceedCapacity = false

        init(capacity: Int) {
            self.capacity = max(0, capacity)
        }

        mutating func insert(_ value: String) {
            guard capacity > 0 else {
                didExceedCapacity = true
                return
            }
            guard values.count < capacity else {
                didExceedCapacity = true
                guard isOrderedAfter(values[0], than: value) else { return }
                values[0] = value
                siftDown(from: 0)
                return
            }
            values.append(value)
            siftUp(from: values.index(before: values.endIndex))
        }

        var sortedValues: [String] {
            values.sorted(by: precedes)
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard isOrderedAfter(values[child], than: values[parent]) else { break }
                values.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < values.count else { return }
                var largest = left
                let right = left + 1
                if right < values.count,
                   isOrderedAfter(values[right], than: values[left]) {
                    largest = right
                }
                guard isOrderedAfter(values[largest], than: values[parent]) else { return }
                values.swapAt(parent, largest)
                parent = largest
            }
        }

        private func isOrderedAfter(_ lhs: String, than rhs: String) -> Bool {
            switch lhs.localizedStandardCompare(rhs) {
            case .orderedDescending:
                return true
            case .orderedAscending:
                return false
            case .orderedSame:
                return lhs > rhs
            @unknown default:
                return lhs > rhs
            }
        }

        private func precedes(_ lhs: String, _ rhs: String) -> Bool {
            switch lhs.localizedStandardCompare(rhs) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs < rhs
            @unknown default:
                return lhs < rhs
            }
        }
    }
}
