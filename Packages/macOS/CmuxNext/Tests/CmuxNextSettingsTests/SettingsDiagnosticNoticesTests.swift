import CmuxNextSettings
import Testing

/// A value cmux-next.json sets that the running build refuses is announced
/// once (a toast names the key, the value and why), not again on every
/// reload, and again only after it was fixed and broken anew.
struct SettingsDiagnosticNoticesTests {
    private let background = SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                message: "expected none, daily, desktop, bundled art, folder:<absolute path>, or an absolute system wallpaper or image path")
    private let accent = SettingsDiagnostic(kind: .invalidValue, path: "appearance.accent", message: "expected one of blue, red")

    private func file(_ background: JSONValue, accent: JSONValue? = nil) -> JSONValue {
        var appearance: [String: JSONValue] = ["background": background]
        if let accent { appearance["accent"] = accent }
        return .object(["appearance": .object(appearance)])
    }

    /// One load whose pending notices a toast then showed.
    private func load(_ notices: inout SettingsDiagnosticNotices, _ diagnostics: [SettingsDiagnostic], file: JSONValue,
                      managed: Set<String> = []) -> SettingsDiagnosticNotices.Update {
        let update = notices.update(diagnostics, file: file, managed: managed)
        notices.announced(update.announce)
        return update
    }

    @Test func aRefusedValueIsAnnouncedWithItsKeyValueAndReason() {
        var notices = SettingsDiagnosticNotices()
        let update = load(&notices, [background], file: file("folder:~/Pictures"))
        #expect(update.announce.map(\.path) == ["appearance.background"])
        #expect(update.announce.map(\.value) == ["\"folder:~/Pictures\""])
        #expect(update.announce.map(\.message) == [background.message])
        #expect(!update.cleared)
    }

    @Test func theSameRefusalIsNotAnnouncedAgainOnReload() {
        var notices = SettingsDiagnosticNotices()
        _ = load(&notices, [background], file: file("folder:~/Pictures"))
        let again = load(&notices, [background], file: file("folder:~/Pictures"))
        #expect(again.announce.isEmpty)
        #expect(!again.cleared)
    }

    @Test func aRefusalAnnouncedAtAnEarlierLaunchStaysQuiet() {
        var first = SettingsDiagnosticNotices()
        _ = load(&first, [background], file: file("folder:~/Pictures"))
        var relaunched = SettingsDiagnosticNotices(remembered: first.remembered)
        #expect(load(&relaunched, [background], file: file("folder:~/Pictures")).announce.isEmpty)
    }

    @Test func theRememberedFingerprintHoldsNoRawValue() {
        var notices = SettingsDiagnosticNotices()
        _ = load(&notices, [background], file: file("folder:/Users/someone/Secret Photos"))
        #expect(notices.remembered.count == 1)
        #expect(!notices.remembered.contains { $0.contains("Secret Photos") })
    }

    @Test func aRefusalNoToastShowedStaysPending() {
        var notices = SettingsDiagnosticNotices()
        // No window: the app does not call `announced`.
        #expect(notices.update([background], file: file("folder:~/Pictures")).announce.count == 1)
        #expect(notices.update([background], file: file("folder:~/Pictures")).announce.count == 1)
    }

    @Test func anotherBadValueAtTheSameKeyIsAnnounced() {
        var notices = SettingsDiagnosticNotices()
        _ = load(&notices, [background], file: file("folder:~/Pictures"))
        let changed = load(&notices, [background], file: file(42))
        #expect(changed.announce.map(\.value) == ["42"])
    }

    @Test func aFixClearsTheNoticeAndANewBreakAnnouncesAgain() {
        var notices = SettingsDiagnosticNotices()
        _ = load(&notices, [background], file: file("folder:~/Pictures"))
        let fixed = load(&notices, [], file: file("daily"))
        #expect(fixed.announce.isEmpty)
        #expect(fixed.cleared)
        let quiet = load(&notices, [], file: file("daily"))
        #expect(!quiet.cleared)
        let broken = load(&notices, [background], file: file("folder:~/Pictures"))
        #expect(broken.announce.count == 1)
    }

    @Test func fixingTheShownRefusalClearsItWhileAnotherStays() {
        var notices = SettingsDiagnosticNotices()
        let first = load(&notices, [background, accent], file: file("folder:~/Pictures", accent: "teal"))
        #expect(first.announce.first?.path == "appearance.background")
        let partial = load(&notices, [accent], file: file("daily", accent: "teal"))
        #expect(partial.cleared)
        #expect(partial.announce.isEmpty)
    }

    @Test func managedKeysAndShortcutConflictsAreNotAnnounced() {
        var notices = SettingsDiagnosticNotices()
        let update = load(&notices, [
            SettingsDiagnostic(kind: .managedOverride, path: "updates.channel", message: "managed by MDM"),
            SettingsDiagnostic(kind: .managedConflict, path: "updates.channel", message: "MDM wins"),
            SettingsDiagnostic(kind: .shortcutConflict, path: "shortcuts.bindings.newTab", message: "also used by newWindow"),
        ], file: .object([:]))
        #expect(update.announce.isEmpty)
    }

    @Test func badValuesAManagedLayerSetsAreNotAnnounced() {
        var notices = SettingsDiagnosticNotices()
        let update = load(&notices, [
            // An MDM-forced value the schema refuses: the merged root holds it, not the person's file.
            SettingsDiagnostic(kind: .invalidValue, path: "updates.channel", message: "expected one of stable, nightly"),
            // A malformed policy-only key.
            SettingsDiagnostic(kind: .invalidValue, path: "DisabledFeatures", message: "DisabledFeatures must be an array of feature names"),
            background,
        ], file: file("folder:~/Pictures"), managed: ["updates.channel", "DisabledFeatures"])
        #expect(update.announce.map(\.path) == ["appearance.background"])
    }

    @Test func anUnreadableFileIsAnnouncedWithoutAValue() {
        var notices = SettingsDiagnosticNotices()
        let update = load(&notices, [SettingsDiagnostic(kind: .unreadableFile, path: "", message: "unexpected character at line 3")],
                          file: .object([:]))
        #expect(update.announce.map(\.path) == [""])
        #expect(update.announce.map(\.value) == [nil])
    }

    @Test func anUnreadableFileIsAnnouncedOnceWhereverTheErrorMoves() {
        var notices = SettingsDiagnosticNotices()
        _ = load(&notices, [SettingsDiagnostic(kind: .unreadableFile, path: "", message: "unexpected character at line 3")], file: .object([:]))
        let moved = load(&notices, [SettingsDiagnostic(kind: .unreadableFile, path: "", message: "unexpected character at line 4")],
                         file: .object([:]))
        #expect(moved.announce.isEmpty)
    }
}
