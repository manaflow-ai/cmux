import CmuxNextSettings
import Testing

/// A value cmux-next.json sets that the running build refuses is announced
/// once (a toast names the key, the value and why), not again on every
/// reload, and again only after it was fixed and broken anew.
struct SettingsDiagnosticNoticesTests {
    private let background = SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                message: "expected none, daily, desktop, bundled art, folder:<absolute path>, or an absolute system wallpaper or image path")

    private func file(_ background: JSONValue) -> JSONValue {
        .object(["appearance": .object(["background": background])])
    }

    @Test func aRefusedValueIsAnnouncedWithItsKeyValueAndReason() {
        var notices = SettingsDiagnosticNotices()
        let update = notices.update([background], file: file("folder:~/Pictures"))
        #expect(update.announce == [SettingsDiagnosticNotices.Notice(path: "appearance.background", value: "\"folder:~/Pictures\"",
                                                                     message: background.message)])
        #expect(!update.cleared)
    }

    @Test func theSameRefusalIsNotAnnouncedAgainOnReload() {
        var notices = SettingsDiagnosticNotices()
        _ = notices.update([background], file: file("folder:~/Pictures"))
        let again = notices.update([background], file: file("folder:~/Pictures"))
        #expect(again.announce.isEmpty)
        #expect(!again.cleared)
    }

    @Test func anotherBadValueAtTheSameKeyIsAnnounced() {
        var notices = SettingsDiagnosticNotices()
        _ = notices.update([background], file: file("folder:~/Pictures"))
        let changed = notices.update([background], file: file(42))
        #expect(changed.announce.map(\.value) == ["42"])
    }

    @Test func aFixClearsTheNoticeAndANewBreakAnnouncesAgain() {
        var notices = SettingsDiagnosticNotices()
        _ = notices.update([background], file: file("folder:~/Pictures"))
        let fixed = notices.update([], file: file("daily"))
        #expect(fixed.announce.isEmpty)
        #expect(fixed.cleared)
        let quiet = notices.update([], file: file("daily"))
        #expect(!quiet.cleared)
        let broken = notices.update([background], file: file("folder:~/Pictures"))
        #expect(broken.announce.count == 1)
    }

    @Test func managedKeysAndShortcutConflictsAreNotAnnounced() {
        var notices = SettingsDiagnosticNotices()
        let update = notices.update([
            SettingsDiagnostic(kind: .managedOverride, path: "updates.channel", message: "managed by MDM"),
            SettingsDiagnostic(kind: .managedConflict, path: "updates.channel", message: "MDM wins"),
            SettingsDiagnostic(kind: .shortcutConflict, path: "shortcuts.bindings.newTab", message: "also used by newWindow"),
        ], file: .object([:]))
        #expect(update.announce.isEmpty)
    }

    @Test func anUnreadableFileIsAnnouncedWithoutAValue() {
        var notices = SettingsDiagnosticNotices()
        let update = notices.update([SettingsDiagnostic(kind: .unreadableFile, path: "", message: "unexpected character at line 3")],
                                    file: .object([:]))
        #expect(update.announce == [SettingsDiagnosticNotices.Notice(path: "", value: nil, message: "unexpected character at line 3")])
    }
}
