import Foundation

extension ChromiumPageHostBridge {
    // MARK: Pushes

    /// One thing to run in the page: a script text, or a fixed body called with its data.
    enum Push {
        case script(String)
        case call(body: String, name: String, text: String)

        var bytes: Int {
            switch self {
            case .script(let script): script.utf8.count
            case .call(_, _, let text): text.utf8.count
            }
        }

        var script: String? {
            if case .script(let script) = self { return script }
            return nil
        }

        var text: String? {
            if case .call(_, _, let text) = self { return text }
            return nil
        }

        /// Whether `other` can go in the same round trip after this.
        func joins(_ other: Push) -> Bool {
            switch (self, other) {
            case (.script, .script): true
            case let (.call(body, name, _), .call(otherBody, otherName, _)): body == otherBody && name == otherName
            default: false
            }
        }

        /// How many pushes at the head of `queue` go in one round trip: those that join the first,
        /// up to ``ChromiumPageHostBridge/maximumBatchBytes`` (at least one, when there is one).
        static func batchCount(_ queue: [Push]) -> Int {
            guard let first = queue.first else { return 0 }
            var bytes = 0
            var count = 0
            for push in queue {
                bytes += push.bytes
                if count > 0, bytes > ChromiumPageHostBridge.maximumBatchBytes || !first.joins(push) { break }
                count += 1
            }
            return count
        }
    }

    /// The one function text a body's pushes call: each text of the array argument in turn, as the
    /// string parameter `name` of `body`, one that throws not stopping the ones after it.
    nonisolated static func callDeclaration(body: String, argument name: String) -> String {
        "function (texts) { const run = (\(name)) => { \(body) }; "
            + "for (const text of texts) { try { run(text) } catch (e) { console.error(e) } } }"
    }

    /// The most script bytes sent in one `Runtime.evaluate`.
    nonisolated static let maximumBatchBytes = 2 << 20

    /// One expression that runs `scripts` in order, each in its own block, so that one that throws
    /// does not stop the ones after it (as separate evaluations did) and their declarations do not meet.
    /// A single script is sent as it is.
    nonisolated static func batch(_ scripts: [String]) -> String {
        guard scripts.count > 1 else { return scripts.first ?? "" }
        return scripts.map { "try {\n\($0)\n} catch (e) { console.error(e) }" }.joined(separator: "\n")
    }
}
