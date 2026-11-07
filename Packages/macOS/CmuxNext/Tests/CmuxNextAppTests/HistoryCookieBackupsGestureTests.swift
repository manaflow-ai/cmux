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
}
