extension WorkspaceTerminalFontSizeCoordinator {
    struct PendingRequestQueue {
        private var storage: [PendingRequest] = []
        private var head = 0

        var isEmpty: Bool {
            head >= storage.count
        }

        var count: Int {
            storage.count - head
        }

        var elements: ArraySlice<PendingRequest> {
            storage[head...]
        }

        var first: PendingRequest? {
            guard !isEmpty else { return nil }
            return storage[head]
        }

        mutating func append(_ request: PendingRequest) {
            storage.append(request)
        }

        mutating func popFirst() -> PendingRequest? {
            guard !isEmpty else { return nil }
            let request = storage[head]
            head += 1
            if head == storage.count {
                storage.removeAll(keepingCapacity: false)
                head = 0
            } else if head >= 16, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return request
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
        }

        mutating func removeAll(
            where shouldRemove: (PendingRequest) -> Bool
        ) -> [PendingRequest] {
            var removed: [PendingRequest] = []
            var retained: [PendingRequest] = []
            for request in elements {
                if shouldRemove(request) {
                    removed.append(request)
                } else {
                    retained.append(request)
                }
            }
            storage = retained
            head = 0
            return removed
        }
    }
}
