struct ChromiumViewportInputQueue {
    static let maximumPendingCommands = 64

    private(set) var commands: [ChromiumViewportInputCommand] = []

    var count: Int { commands.count }

    /// Enqueues input while retaining the newest complete gestures under pressure.
    ///
    /// - Returns: `false` only when the queue contains no fully closed gesture that
    ///   can be discarded without separating a press from its release.
    @discardableResult
    mutating func enqueue(_ command: ChromiumViewportInputCommand) -> Bool {
        if let coalescingKind = command.coalescingKind {
            let currentOrderingSegmentStart = commands.lastIndex(where: {
                $0.coalescingKind == nil
            }).map { $0 + 1 } ?? commands.startIndex
            if let existingIndex = commands[currentOrderingSegmentStart...].firstIndex(where: {
                $0.coalescingKind == coalescingKind
            }) {
                commands[existingIndex] = commands[existingIndex].coalescing(with: command)
                return true
            }
        }

        if commands.count == Self.maximumPendingCommands {
            if let coalescibleIndex = commands.firstIndex(where: {
                $0.coalescingKind != nil
            }) {
                commands.remove(at: coalescibleIndex)
            } else if case .ended(let gesture)? = command.gestureTransition,
                      commands.contains(where: {
                          $0.gestureTransition == .began(gesture)
                      }) {
                commands.removeAll(where: {
                    $0.gestureTransition == .began(gesture)
                })
                commands.append(command)
                return true
            } else if !discardOldestCompleteGesture() {
                return false
            }
        }
        commands.append(command)
        return true
    }

    mutating func popFirst() -> ChromiumViewportInputCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func removeAll() {
        commands.removeAll(keepingCapacity: true)
    }

    private mutating func discardOldestCompleteGesture() -> Bool {
        for startIndex in commands.indices {
            guard case .began(let firstGesture)? = commands[startIndex].gestureTransition else {
                continue
            }
            var activeGestures: Set<String> = [firstGesture]
            var endIndex = commands.index(after: startIndex)
            var isBalanced = true
            while endIndex < commands.endIndex {
                switch commands[endIndex].gestureTransition {
                case .began(let gesture):
                    activeGestures.insert(gesture)
                case .ended(let gesture):
                    if activeGestures.contains(gesture) {
                        activeGestures.remove(gesture)
                    } else {
                        isBalanced = false
                    }
                case nil:
                    break
                }
                guard isBalanced else { break }
                if activeGestures.isEmpty {
                    commands.removeSubrange(startIndex...endIndex)
                    return true
                }
                endIndex = commands.index(after: endIndex)
            }
        }
        return false
    }
}
