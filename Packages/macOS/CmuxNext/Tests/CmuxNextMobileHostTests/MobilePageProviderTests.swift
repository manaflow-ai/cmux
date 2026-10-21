import AppKit
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import CmuxNextPages
import CmuxNextSettings
import Testing

/// Settings > Mobile's ops: only the person's gesture on the Settings page removes a phone.
@MainActor @Suite struct MobilePageProviderTests {
    @Test func removeNeedsTheSettingsPageAndAGesture() async throws {
        let provider = MobilePageProvider(host: IPhoneHostService())
        let params: JSONValue = ["id": "phone-1"]
        for context in [PageCallContext(page: "cmux.settings"), PageCallContext(page: "cmux.history", userGesture: true)] {
            await #expect(throws: PageError.self) { _ = try await provider.call("cmux.settings.mobile.remove_phone", params: params, context: context) }
        }
        let answer = try await provider.call("cmux.settings.mobile.remove_phone", params: params,
                                             context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(answer == .object([:]))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.remove_phone", params: .object([:]),
                                        context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.other", params: params, context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
    }

    @Test func allowAgainNeedsTheSettingsPageAndAGesture() async throws {
        let provider = MobilePageProvider(host: IPhoneHostService())
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.allow_again", params: .object([:]), context: PageCallContext(page: "cmux.settings"))
        }
        let answer = try await provider.call("cmux.settings.mobile.allow_again", params: .object([:]),
                                             context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(answer == .object([:]))
    }

    /// A pairing request is answered only by the person: the prompt (which `debug.dialog` may not
    /// press) or their own click on Settings > Mobile, never a script or another page.
    @Test func answeringAPairingRequestNeedsTheSettingsPageAndAGesture() async throws {
        let host = IPhoneHostService()
        let provider = MobilePageProvider(host: host)
        let params: JSONValue = ["id": "phone-1", "allow": true]
        for context in [PageCallContext(page: "cmux.settings"), PageCallContext(page: "cmux.history", userGesture: true)] {
            do {
                _ = try await provider.call("cmux.settings.mobile.answer_pair", params: params, context: context)
                Issue.record("answered without the person's gesture on Settings")
            } catch let error as PageError {
                #expect(error.code == "cmux.settings.user_only")
            }
        }
        // The person's gesture, but no request from that phone waits.
        do {
            _ = try await provider.call("cmux.settings.mobile.answer_pair", params: params,
                                        context: PageCallContext(page: "cmux.settings", userGesture: true))
            Issue.record("answered a request that does not wait")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.invalid_params")
        }
        #expect(host.answerPairRequest(id: "phone-1", allow: true) == false)
        #expect(IPhoneHostService.pairDialogIdentifier == "cmux.dialog.iphonePair")
    }

    /// The pairing prompt is a sheet on a cmux window on screen, never a floating
    /// window: with no window, or a hidden one, it waits for one.
    @Test func thePairingPromptAttachesToAVisibleWindowOrWaits() {
        #expect(IPhoneHostService.pairScope(window: nil) == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(IPhoneHostService.pairScope(window: window) == nil)
        window.orderFrontRegardless()
        defer { window.close() }
        if window.isVisible {
            #expect(IPhoneHostService.pairScope(window: window)?.kind == "window")
            window.miniaturize(nil)
            if window.isMiniaturized { #expect(IPhoneHostService.pairScope(window: window) == nil) }
        }
    }

    @Test func theRegistrationDateReadsTodayYesterdayOrADate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(IPhoneHostStrings.deviceRegistered(now.addingTimeInterval(-60), now: now, calendar: calendar) == "Registered today")
        #expect(IPhoneHostStrings.deviceRegistered(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Registered yesterday")
        let older = IPhoneHostStrings.deviceRegistered(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar)
        #expect(older.hasPrefix("Registered ") && older != "Registered today" && older != "Registered yesterday")
    }

    @Test func theBannerReviewsInSettingsMobile() {
        let category = IPhonePairNotices.notificationCategory()
        #expect(category.identifier == IPhonePairNotices.category)
        #expect(category.actions.map(\.identifier) == [IPhonePairNotices.reviewAction])
        #expect(category.actions.first?.options.contains(.foreground) == true)
        #expect(IPhonePairNotices.settingsRoute == "#/settings/mobile")
    }

    /// Settings > Mobile is the one phone list: each row names its app, and Remove on a cmux next
    /// row forgets it in the shared store, which closes its Iroh sessions (PhoneAdmissionTests).
    @Test func eachPhoneRowNamesItsAppAndRemoveForgetsAnIrohPhone() async throws {
        final class Removed: @unchecked Sendable { var ids: [String] = [] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = IPhoneHostService()
        host.pairedStore.attach(directory: directory)
        host.pairedStore.load(userID: "u")
        let key = String(repeating: "ab", count: 32)
        let iroh = MobileHostPairRequest(phoneDeviceID: key, name: "Aziz's iPhone", identityKey: key, approvalKey: "", transport: .iroh)
        try host.pairedStore.change { $0.approve(iroh, at: Date()) }
        host.syncPaired()
        // Signed out of hostd's connections, the cmux next phone still lists.
        guard case .array(let alone)? = host.pageJSON["phones"] else { Issue.record("no phones"); return }
        #expect(alone.map { $0["app"] } == [.string("cmux next")])
        host.allowed = true
        host.knownPhones = [MobileHostKnownPhone(name: "Aziz's iPhone", deviceIDs: ["p1"], updatedAt: nil)]
        guard case .array(let rows)? = host.pageJSON["phones"] else { Issue.record("no phones"); return }
        #expect(rows.map { $0["app"] } == [.string("cmux (iOS)"), .string("cmux next")])
        #expect(rows.map { $0["subtitle"]?.stringValue?.hasPrefix(($0["app"]?.stringValue ?? "?") + " · ") } == [true, true])
        #expect(rows.last?["id"] == .string(key) && rows.last?["removable"] == .bool(true))
        let removed = Removed()
        host.pairedStore.observe { change in removed.ids += change.removed.map(\.id) }
        let provider = MobilePageProvider(host: host)
        _ = try await provider.call("cmux.settings.mobile.remove_phone", params: ["id": .string(key)],
                                    context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(removed.ids == [key])
        #expect(host.pairedStore.current?.devices.isEmpty == true)
        #expect(host.paired?.devices.isEmpty == true)
    }

    @Test func aHostWithNoAccountShowsOffWithNoPhones() {
        let json = IPhoneHostService().pageJSON
        #expect(json["allowed"] == .bool(false))
        #expect(json["phase"] == .string("off"))
        #expect(json["account"] == .null)
        #expect(json["phones"] == .array([]))
        #expect(json["pending"] == .array([]))
        #expect(json["blocked"] == .null)
    }
}
