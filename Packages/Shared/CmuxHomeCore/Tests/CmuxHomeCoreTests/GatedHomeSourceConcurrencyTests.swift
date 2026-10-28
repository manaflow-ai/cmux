import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// `GatedHomeSource` keeps its record in one `Mutex<State>`
/// (was an `@unchecked Sendable` class over an NSLock). Reads and closes from many
/// tasks at once each land in the record exactly once, and a held read waits until
/// `release()`. Run under TSan as well (`swift test --sanitize=thread`).
@MainActor
@Suite struct GatedHomeSourceConcurrencyTests {
    static let readers = 64

    @Test func concurrentReadsAndClosesEachLandOnceInTheRecord() async {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let ids = (0..<Self.readers).map { ConversationID("conv_gate_\($0)") }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = try? await source.snapshot(of: id, tail: 1)
                    source.close(id)
                }
            }
        }
        #expect(Set(source.snapshots) == Set(ids))
        #expect(source.snapshots.count == ids.count)
        #expect(Set(source.closes) == Set(ids))
        #expect(source.closes.count == ids.count)
        for id in ids {
            let steps = source.journal.filter { $0 == .read(id) || $0 == .readReturned(id) || $0 == .close(id) }
            #expect(steps == [.read(id), .readReturned(id), .close(id)], "\(id): \(steps)")
        }
        #expect(source.waiting == 0)
    }

    @Test func heldReadsFromManyTasksAllWaitThenAllReturnOnRelease() async {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let ids = (0..<Self.readers).map { ConversationID("conv_held_\($0)") }
        source.hold()
        let reading = Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { _ = try? await source.snapshot(of: id, tail: 1) }
                }
            }
        }
        await waitUntil { source.waiting == ids.count }
        #expect(!source.journal.contains(where: Self.isReturn), "a held read returned before release()")
        source.release()
        await reading.value
        #expect(source.waiting == 0)
        #expect(source.journal.filter(Self.isReturn).count == ids.count)

        // Not holding any more: a later read passes straight through.
        let late = ConversationID("conv_late")
        _ = try? await source.snapshot(of: late, tail: 1)
        #expect(Array(source.journal.suffix(2)) == [.read(late), .readReturned(late)])
    }

    private static func isReturn(_ step: GatedHomeSource.Step) -> Bool {
        if case .readReturned = step { return true }
        return false
    }
}
