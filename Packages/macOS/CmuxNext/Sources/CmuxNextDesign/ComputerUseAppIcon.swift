public import AppKit
import CmuxNextCompat

/// The icon of the app that holds the Computer Use grants (the Screen Sharing helper, or cmux
/// Remote), for the rows that ask the person to drag it into System Settings' Privacy & Security
/// lists: onboarding's drag row and the agent permission card.
///
/// A helper bundle that names no icon (built before its bundle carried one, or a copy staged from
/// such a build) makes `NSWorkspace.icon(forFile:)` answer the generic blank app. The row then
/// draws Computer Use's own icon (`Resources/ComputerUseIcon.icns`, the cursor icon "cmux Computer
/// Use.app" ships with) instead, so the row and its drag image never show the blank one.
public nonisolated struct ComputerUseAppIcon {
    public nonisolated init() {}
    private final class Anchor {}

    /// The bundled Computer Use icon; nil only when the resource bundle is gone.
    public static var bundled: NSImage? {
        guard let url = ModuleResourceBundle(cmuxNextTarget: "CmuxNextDesign", anchor: Anchor.self).bundle?
            .url(forResource: "ComputerUseIcon", withExtension: "icns"),
              let data = try? Data(blockingContentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// `appURL`'s own icon when its bundle names one, else the bundled Computer Use icon (else the
    /// file's icon, the generic one, when both are missing).
    public static func image(forApp appURL: URL) -> NSImage {
        if declaresIcon(appURL) { return NSWorkspace.shared.icon(forFile: appURL.path) }
        return bundled ?? NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// Whether the app bundle at `appURL` carries an icon of its own: an icon file its Info.plist
    /// names (`CFBundleIconFile`, with or without `.icns`), or an asset catalog icon
    /// (`CFBundleIconName` with `Assets.car`). Without one macOS draws the generic blank app.
    public static func declaresIcon(_ appURL: URL) -> Bool {
        let contents = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
        guard let data = FileManager.checked.contents(atPath: contents.appending(path: "Info.plist").path),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        let files = FileManager.checked
        if let name = info["CFBundleIconFile"] as? String, !name.isEmpty, !name.contains("/") {
            let file = name.hasSuffix(".icns") ? name : name + ".icns"
            if files.fileExists(atPath: resources.appending(path: file).path) { return true }
        }
        if let name = info["CFBundleIconName"] as? String, !name.isEmpty {
            if files.fileExists(atPath: resources.appending(path: "Assets.car").path) { return true }
        }
        return false
    }
}
