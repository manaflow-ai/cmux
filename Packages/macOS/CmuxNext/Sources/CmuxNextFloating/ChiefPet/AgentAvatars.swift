public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import ImageIO
import UniformTypeIdentifiers

/// The person's own avatar for each agent session (Leo 2026-10-26: "upload their own if they have
/// things from elsewhere for the avatars"), kept by the Chief avatars' store under the session's key
/// (``ChiefAvatarUploads/key(agent:)``) on this Mac only, with the same limits. The agent chat's ⋯
/// menu sets and removes it (Set Avatar…, Remove Avatar); its cards and its sender chip draw it in
/// place of the harness mark, as a small data URL the page asks for (`agent.avatar`).
@MainActor
public final class AgentAvatars {
    /// The side of the picture the page draws (its cards and chips draw it at 14 to 28 points).
    nonisolated static let side = 96
    /// An agent's upload is worn whatever character is picked: this stands for "always".
    nonisolated static let worn = "agent"

    private let uploads: ChiefAvatarUploads
    private let openPanel: MadeAheadOpenPanel?
    /// Each upload's small picture, by its still (each upload's still has its own name).
    private var made: [URL: String] = [:]

    public init(uploads: ChiefAvatarUploads, openPanel: MadeAheadOpenPanel?) {
        self.uploads = uploads
        self.openPanel = openPanel
    }

    /// Session `session`'s avatar as a data URL, drawn down off the main actor; nil for none. Asked
    /// before the launch listing is published, it waits for it. A picture replaced or removed during
    /// the draw-down is not answered: the newest one is.
    public func avatar(_ session: String) async -> String? {
        let key = ChiefAvatarUploads.key(agent: session)
        await uploads.ready()
        while let still = uploads.uploads[key]?.still {
            if let known = made[still] { return known }
            // task-owner: one small read and draw-down of a 512 px PNG; ends with it
            let src = await Task.detached(priority: WorkPriority.userVisible.taskPriority) { Self.dataURL(still) }.value
            guard uploads.uploads[key]?.still == still else { continue }
            if let src { made[still] = src }
            return src
        }
        return nil
    }

    /// Set Avatar…: the open panel over `window`, then the upload. The new avatar; nil when the
    /// person cancelled, or when the picture was refused (a cmux dialog over `window` says why).
    public func choose(_ session: String, window: NSWindow?) async -> String? {
        guard let window, let panel = openPanel?.panel() else { return nil }
        panel.allowedContentTypes = ChiefAvatarUploads.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let file: URL? = await withCheckedContinuation { done in
            panel.beginSheetModal(for: window) { response in done.resume(returning: response == .OK ? panel.url : nil) }
        }
        guard let file else { return nil }
        do throws(ChiefAvatarUploads.Refusal) {
            try await uploads.store(from: file, for: ChiefAvatarUploads.key(agent: session), over: Self.worn)
        } catch {
            let spec = CmuxDialogSpec(title: error.message, buttons: [.ok()], identifier: "cmux.dialog.agentAvatar.refused")
            _ = await CmuxDialogCenter.shared.present(spec, in: .window(window))
            return nil
        }
        return await avatar(session)
    }

    /// Remove Avatar: the session's harness mark shows again.
    public func remove(_ session: String) {
        uploads.remove(ChiefAvatarUploads.key(agent: session))
    }

    /// The still at `file` drawn down to ``side`` as a PNG data URL (off the main actor).
    nonisolated static func dataURL(_ file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        let png = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (png as Data).base64EncodedString()
    }
}
