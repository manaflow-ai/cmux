import CmuxMobileTransport
import Foundation

/// A Cloud machine's desktop, streamed view only over the paired Mac's
/// `surface` service on the tab key `c~<machine_id>~<team_id>` (hostd
/// `surface.rs`; https://github.com/manaflow-ai/cmux/issues/31488). The same
/// stream as a simulator tab's, but nothing the phone does reaches the
/// machine: hostd drops input for `c~` keys, and the surface view here never
/// sends any.
///
/// The model is not kept in the directory's tab models: those follow the
/// Macs' tab lists (``StreamedBrowserDirectory/retain(tabs:)``), which never
/// list a Cloud machine. Its owner (the Chief info page's Computer card)
/// keeps it, shows it, and closes it.
extension StreamedBrowserDirectory {
    /// The capability a Mac's host lists when it streams Cloud desktops.
    public static let cloudDesktopCapability = "cloud-desktop-v1"

    /// The `surface` tab key of a Cloud machine's desktop (`~` is never in a Cloud id).
    public static func cloudDesktopTab(machineID: String, teamID: String) -> String {
        "c~\(machineID)~\(teamID)"
    }

    /// A view-only stream of a Cloud machine's desktop over `macID`'s link,
    /// or nil when not linked. `refused` hears the code of a refusal (at open,
    /// or the stream ending with one), such as `asleep` for a machine that
    /// stopped running.
    public func cloudDesktopModel(machineID: String, teamID: String, macID: String,
                                  refused: @escaping @MainActor @Sendable (String) -> Void) -> StreamedBrowserModel? {
        guard isLive else { return nil }
        let tab = Self.cloudDesktopTab(machineID: machineID, teamID: teamID)
        return StreamedBrowserModel(tab: tab, url: nil) { [weak self] sink, tab, _ in
            guard let link = await self?.link(macID: macID) else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            do {
                return try await link.openSurface(tab: tab, sink: RefusalSink(sink, refused: refused))
            } catch let error as LinkError {
                await refused(error.code)
                throw error
            }
        }
    }
}

/// Passes a stream through and reports how it was refused or ended.
final class RefusalSink: BrowserStreamSink, Sendable {
    private let inner: any BrowserStreamSink
    private let refused: @MainActor @Sendable (String) -> Void

    init(_ inner: any BrowserStreamSink, refused: @escaping @MainActor @Sendable (String) -> Void) {
        self.inner = inner
        self.refused = refused
    }

    func browserFrame(_ frame: BrowserStreamFrame) { inner.browserFrame(frame) }

    func browserMessage(_ json: Data) {
        if let code = Self.refusalCode(json) {
            let refused = refused
            Task { @MainActor in refused(code) }
        }
        inner.browserMessage(json)
    }

    func browserClosed(code: String, reason: String) {
        let refused = refused
        Task { @MainActor in refused(code) }
        inner.browserClosed(code: code, reason: reason)
    }

    /// The code of an rd `refused` message, else nil.
    static func refusalCode(_ json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["t"] as? String == "refused" else { return nil }
        return object["code"] as? String
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// A stream's picture with no input: the simulator page's surface view
/// (aspect fit, the model's layout) with touches, the keyboard and direct
/// interaction off. VoiceOver reads it as an image.
public struct StreamedViewOnlySurface: UIViewRepresentable {
    let model: StreamedBrowserModel
    let label: String
    let identifier: String

    public init(model: StreamedBrowserModel, label: String, identifier: String) {
        self.model = model
        self.label = label
        self.identifier = identifier
    }

    public func makeUIView(context: Context) -> UIView {
        let view = SimulatorStreamView(model: model)
        view.isUserInteractionEnabled = false
        view.accessibilityTraits = .image
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityLabel = label
    }
}
#endif
