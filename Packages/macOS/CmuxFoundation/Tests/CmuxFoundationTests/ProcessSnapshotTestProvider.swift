import Foundation

actor ProcessSnapshotTestProvider {
    struct Fields: OptionSet, Sendable {
        let rawValue: Int
        static let paths = Self(rawValue: 1)
        static let scope = Self(rawValue: 2)
    }
    final class Value: Sendable {
        let generation: Int
        let fields: Fields
        init(_ generation: Int, fields: Fields = []) {
            self.generation = generation
            self.fields = fields
        }
    }

    private(set) var captures = 0
    private(set) var enrichments: [Fields] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var blocked = true
    private var pending: CheckedContinuation<Void, Never>?
    let started = AsyncStream<Int>.makeStream()

    func capture() async -> Value {
        captures += 1
        let generation = captures
        active += 1
        maximumActive = max(maximumActive, active)
        if blocked {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.continuation.yield(generation)
            }
        }
        active -= 1
        return Value(generation)
    }

    func enrich(_ value: Value, fields: Fields) -> Value {
        enrichments.append(fields)
        return Value(value.generation, fields: value.fields.union(fields))
    }

    func release(remaining: Bool = false) {
        blocked = remaining
        pending?.resume()
        pending = nil
    }

    func waitForCapture(_ count: Int) async {
        for await generation in started.stream where generation >= count { return }
    }
}
