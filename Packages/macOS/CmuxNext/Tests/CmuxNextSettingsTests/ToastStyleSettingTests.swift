import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `notifications.toast.style`, a theme hook (Leo 2026-11-22: "the toast is this awkward pill glass. im not sure
/// if it should be that rounded."): absent, the toast keeps today's glass; a theme can name `solid` or `flat`.
struct ToastStyleSettingTests {
    @Test func absentKeepsTodaysGlass() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.toastStyle == .standard)
        #expect(SettingsSchema.descriptor(for: ["notifications", "toast", "style"])?.defaultValue == .string("standard"))
    }

    @Test func aThemeCanMakeTheToastFlat() {
        let root = JSONValue.object(["notifications": .object(["toast": .object(["style": .string("flat")])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.toastStyle == .flat)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("notifications.toast") })
    }

    @Test func anUnknownStyleKeepsTheDefaultWithADiagnostic() {
        let root = JSONValue.object(["notifications": .object(["toast": .object(["style": .string("pill")])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.toastStyle == .standard)
        #expect(snapshot.diagnostics.contains { $0.path == "notifications.toast.style" })
    }
}
