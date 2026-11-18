import CmuxNextDesign
@testable import CmuxNextHistoryPages
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Cookie Backups delete (`cmux.history.cookie_backups.delete`): one click asks one question. A
/// second delete off the same gesture is refused before any dialog, so a page script cannot stack
/// confirmation dialogs on one click; a new click asks again.
@MainActor @Suite(.serialized)
struct HistoryCookieBackupsGestureTests {
    static func click(_ at: TimeInterval?) -> PageCallContext {
        PageCallContext(page: "cmux.history", userGesture: at != nil, gestureEvent: at)
    }

    static func delete(_ provider: HistoryCookieBackupsPageProvider, _ context: PageCallContext) async throws -> JSONValue {
        try await provider.call(HistoryCookieBackupsPageProvider.prefix + "delete", params: ["ids": ["b1"]], context: context)
    }

    static func refused(_ provider: HistoryCookieBackupsPageProvider, _ context: PageCallContext) async -> Bool {
        do {
            _ = try await delete(provider, context)
            return false
        } catch let error as PageError {
            return error.code == PageNativeOp.userOnlyCode
        } catch {
            return false
        }
    }

    @Test func aSecondDeleteOffOneClickIsRefusedBeforeItsDialog() async throws {
        let provider = HistoryCookieBackupsPageProvider { nil }
        var asked = 0
        provider.confirm = { _, _ in
            asked += 1
            return false
        }
        #expect(try await Self.delete(provider, Self.click(10)) == ["confirmed": false])
        #expect(await Self.refused(provider, Self.click(10)), "a second delete off the same click went through")
        #expect(asked == 1, "one click asked \(asked) times")

        // A new click asks again.
        #expect(try await Self.delete(provider, Self.click(11)) == ["confirmed": false])
        #expect(asked == 2)
    }

    @Test func aDeleteWithNoGestureIsRefused() async throws {
        let provider = HistoryCookieBackupsPageProvider { nil }
        var asked = 0
        provider.confirm = { _, _ in
            asked += 1
            return true
        }
        #expect(await Self.refused(provider, Self.click(nil)))
        #expect(asked == 0)
    }

    /// Malformed `ids` (null, a string, an empty or mixed array) are refused before any dialog.
    @Test func malformedIdsAreRefusedBeforeTheDialog() async throws {
        let provider = HistoryCookieBackupsPageProvider { nil }
        var asked = 0
        provider.confirm = { _, _ in
            asked += 1
            return true
        }
        let malformed: [JSONValue] = [.null, "b1", [], ["b1", 2], ["b1", "b1"]]
        for (index, ids) in malformed.enumerated() {
            do {
                _ = try await provider.call(HistoryCookieBackupsPageProvider.prefix + "delete", params: ["ids": ids],
                                            context: Self.click(TimeInterval(20 + index)))
                Issue.record("\(ids) was not refused")
            } catch let error as PageError {
                #expect(error.code == "cmux.protocol.invalid_params", "\(ids): \(error.code)")
            }
        }
        #expect(asked == 0)
    }

    /// The daemon's side of the rest of `cmux.history.`: records what reaches it.
    final class Relay: PageProvider {
        var sent: [String] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            sent.append(op)
            return .object([:])
        }
    }

    /// cmux#37302: History's remove and clear go to the daemon only on the person's click, each
    /// click once, whatever the daemon checks (an older daemon has no page allow list). Reads
    /// need no click.
    @Test func removeAndClearNeedTheClickBeforeTheDaemon() async throws {
        let provider = HistoryCookieBackupsPageProvider { nil }
        let relay = Relay()
        provider.relay = relay
        func refused(_ op: String, _ context: PageCallContext) async -> Bool {
            do {
                _ = try await provider.call(op, params: [:], context: context)
                return false
            } catch let error as PageError {
                return error.code == PageNativeOp.userOnlyCode
            } catch {
                return false
            }
        }
        for op in HistoryCookieBackupsPageProvider.gestureOperations.sorted() {
            #expect(await refused(op, Self.click(nil)), "\(op) went through without a click")
            #expect(await refused(op, PageCallContext(page: "cmux.history", userGesture: true)), "\(op) went through on a flag alone")
        }
        #expect(relay.sent.isEmpty)
        _ = try await provider.call("cmux.history.entries.list", params: [:], context: Self.click(nil))
        _ = try await provider.call("cmux.history.clear", params: [:], context: Self.click(20))
        #expect(await refused("cmux.history.entries.remove", Self.click(20)), "a second change off the same click went through")
        _ = try await provider.call("cmux.history.site.remove", params: [:], context: Self.click(21))
        #expect(relay.sent == ["cmux.history.entries.list", "cmux.history.clear", "cmux.history.site.remove"])
    }
}
