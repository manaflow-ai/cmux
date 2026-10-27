public import CmuxNextWakeups
import CmuxNextIcons
import CoreGraphics
import Foundation

// memory: fixed: one entry per extension whose action a toolbar showed: its last decoded icon,
// `CEFExtensionAction.iconPixels` (56 px) a side, about 12 KB; a decode on its way is a key and
// its waiting buttons until its reply. The tab content cache owns the one instance of the app.
/// The decoded toolbar icons of the extensions' actions, shared by every tab's toolbar: an icon
/// decoded once for one tab shows in the first update of every other tab's button, and only a PNG
/// not seen before is decoded, on the `.cpu` lane, at the size the toolbar draws it. Chrome keeps
/// one icon per extension action for the profile and every toolbar view takes it synchronously
/// (chrome/browser/ui/extensions/extension_action_view_controller.cc, `GetIcon`;
/// extensions/browser/extension_icon_image.cc).
@MainActor
public final class ExtensionActionIcons {
    /// One extension's PNG (the action's icon with its badge and its disabled look).
    private nonisolated struct Key: Hashable, Sendable {
        let id: String
        let png: Data
    }

    /// Each extension's last decoded icon and the PNG it came from.
    private var icons: [String: (png: Data, bitmap: CGImage)] = [:]
    /// Decodes on their way, with the buttons waiting for each.
    private var waiting: [Key: [@MainActor (CGImage?) -> Void]] = [:]
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    /// Decodes started (a test seam: a second toolbar for a decoded PNG starts none).
    private(set) var decodes = 0

    /// `work` decodes the icons; `mainWork` takes them back to the main thread.
    public init(work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.work = work
        self.mainWork = mainWork
    }

    /// The decoded icon of extension `id` when `png` is the one decoded last for it.
    func icon(id: String, png: Data) -> CGImage? {
        guard let entry = icons[id], entry.png == png else { return nil }
        return entry.bitmap
    }

    /// The last decoded icon of extension `id`, whatever its PNG (another badge, the other enabled state).
    func latest(id: String) -> CGImage? { icons[id]?.bitmap }

    /// Decodes `png` for extension `id` off the main thread and calls `done` with it on the main thread (nil when it
    /// does not decode); a PNG already on its way is decoded once for every caller.
    func decode(id: String, png: Data, done: @escaping @MainActor (CGImage?) -> Void) {
        let key = Key(id: id, png: png)
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        decodes += 1
        // The size Chromium draws the icon at (``CEFExtensionAction/iconPixels``): a larger PNG is scaled down once.
        let pixels = Int(CEFExtensionAction.iconPixels)
        work.run(.userVisible, mayBlock: .cpu) {
            IconAssetDecode.thumbnail(png, types: IconAssetDecode.bitmapTypes, maxPixelSize: pixels)
        }.reply(on: mainWork, class: .visible, owner: "ExtensionActionIcons.decoded") { [weak self] bitmap in
            self?.decoded(key, bitmap)
        }
    }

    private func decoded(_ key: Key, _ bitmap: CGImage?) {
        let callers = waiting.removeValue(forKey: key) ?? []
        if let bitmap { icons[key.id] = (key.png, bitmap) }
        for done in callers { done(bitmap) }
    }
}
