import Foundation

/// The person's inputs to the Chief's computer (Chief computer take-over), sent one at a time in
/// order by a single consumer. While one is on its way, the next ones wait here and coalesce: a
/// scroll in the same direction adds to the waiting scroll, consecutive typed text joins, and a
/// double-click replaces the single click it grew from. ``drop()`` forgets every waiting input at
/// once (Give Back, the tab closing) and hands back the one in flight, so Give Back can follow it;
/// the queue then takes no input until ``resume()`` (the person drives again).
@MainActor
final class HomeChiefComputerInputQueue {
    /// The most steps one scroll input moves.
    static let maxScroll = 30

    /// Sends one input; nil sends nothing.
    var send: ((HomeChiefComputerInput) async throws -> Void)?
    /// An input the computer refused while it was still wanted (no ``drop()`` since it was queued).
    var failed: () -> Void = {}
    /// Inputs waiting for the one in flight (tests).
    private(set) var waiting: [HomeChiefComputerInput] = []
    /// The input on its way, if any.
    private(set) var inFlight: Task<Void, Never>?
    /// Dropped and not resumed: new inputs are ignored.
    private(set) var held = false
    /// Bumped by ``drop()``: a send from an older generation says nothing when it fails.
    private var generation = 0

    /// `input` clamped to what one input may carry (a scroll moves 1...30 steps).
    static func clamped(_ input: HomeChiefComputerInput) -> HomeChiefComputerInput {
        guard case let .scroll(x, y, direction, amount) = input else { return input }
        return .scroll(x: x, y: y, direction: direction, amount: min(max(amount, 1), maxScroll))
    }

    /// `next` folded into `last` (the input waiting before it), or nil when both must go.
    static func coalesce(_ last: HomeChiefComputerInput, _ next: HomeChiefComputerInput) -> HomeChiefComputerInput? {
        switch (last, next) {
        case let (.scroll(_, _, before, amount), .scroll(x, y, direction, more)) where before == direction:
            return .scroll(x: x, y: y, direction: direction, amount: min(amount + more, maxScroll))
        case let (.type(text), .type(more)):
            return .type(text + more)
        case let (.click(x, y, button, count), .click(nextX, nextY, nextButton, nextCount))
            where x == nextX && y == nextY && button == nextButton && nextCount > count && nextCount >= 2:
            // The press that made a double-click: the click still waiting was its first press.
            return .click(x: x, y: y, button: button, count: nextCount)
        default:
            return nil
        }
    }

    /// Queues `input` after the ones before it and starts sending when nothing is on its way.
    func enqueue(_ input: HomeChiefComputerInput) {
        guard send != nil, !held else { return }
        let input = Self.clamped(input)
        if let last = waiting.last, let merged = Self.coalesce(last, input) {
            waiting[waiting.count - 1] = merged
        } else {
            waiting.append(input)
        }
        pump()
    }

    /// Forgets every waiting input and returns the one in flight (await it to act after it). A
    /// refusal of that input says nothing now: the person no longer wants it sent.
    @discardableResult
    func drop() -> Task<Void, Never>? {
        generation += 1
        held = true
        waiting.removeAll()
        return inFlight
    }

    /// Takes inputs again after ``drop()``.
    func resume() {
        held = false
    }

    /// ``drop()``, and stops waiting for the input in flight (the profile closed).
    func cancel() {
        drop()?.cancel()
        inFlight = nil
    }

    private func pump() {
        guard inFlight == nil, !waiting.isEmpty, let send else { return }
        let input = waiting.removeFirst()
        let generation = generation
        // task-owner: the one input on its way; the queue's single consumer starts the next when it ends
        inFlight = Task { [weak self] in
            do {
                try await send(input)
            } catch {
                if let self, !Task.isCancelled, self.generation == generation { self.failed() }
            }
            guard let self, !Task.isCancelled else { return }
            self.inFlight = nil
            self.pump()
        }
    }
}
