public import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextHome
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Localized strings of the chief experiment.
public nonisolated enum ChiefStrings {
    public static var title: String {
        String(localized: "chief.title", defaultValue: "Chief (experiment)", bundle: .module)
    }

    static var connecting: String {
        String(localized: "chief.connecting", defaultValue: "Connecting to Chief…", bundle: .module)
    }

    static func notConfigured(_ path: String) -> String {
        String(localized: "chief.notConfigured", defaultValue: "Chief is not configured. Add \(path) with the Worker URL and token.",
               bundle: .module)
    }
}

/// One chief conversation in a tab: the shared Home store fed by
/// `ChiefHomeSource`, rendered by the shared native transcript. A label shows
/// until the first inbox arrives (the transcript needs `me` to be created).
@MainActor
public final class ChiefView: NSView {
    private let store: HomeStore?
    private let conversation: ConversationID?
    private let status = NSTextField(labelWithString: "")
    private var transcript: HomeNativeTranscriptView?
    private var binding: HomeStoreBinding?
    private var waitTask: Task<Void, Never>?

    /// Reads the experiment config; without one the view says where it goes.
    public init(config: ChiefExperimentConfig? = ChiefExperimentConfig.load()) {
        if let config {
            let source = ChiefHomeSource(config: config)
            store = HomeStore(source: source)
            conversation = source.conversation
        } else {
            store = nil
            conversation = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 0
        addSubview(status)
        guard let store, let conversation else {
            status.stringValue = ChiefStrings.notConfigured(ChiefExperimentConfig.defaultFile.path(percentEncoded: false))
            return
        }
        status.stringValue = ChiefStrings.connecting
        store.start()
        // task-owner: this view (cancelled in close()); event-driven (Observation on store.me)
        waitTask = Task { [weak self] in
            for await me in Observations({ store.me }) {
                guard let self, let me else { continue }
                await store.open(conversation)
                self.showTranscript(me: me.id, store: store, conversation: conversation)
                return
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func showTranscript(me: ParticipantID, store: HomeStore, conversation: ConversationID) {
        guard transcript == nil else { return }
        let view = HomeNativeTranscriptView(conversation: conversation, me: me)
        addSubview(view)
        transcript = view
        binding = HomeStoreBinding(store: store, controller: view.controller)
        status.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(view)
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        transcript?.frame = bounds
        let size = status.sizeThatFits(CGSize(width: max(100, bounds.width - 64), height: .greatestFiniteMagnitude))
        status.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
    }

    /// State and a rendered image of this view for `debug.chief` (preflight
    /// without GUI automation): the layer tree is drawn into a bitmap, so
    /// Liquid Glass parts show flat but rows, text and layout are real.
    public func debugReport() -> ChiefDebugReport {
        let items = transcript?.controller.accessibilityItems() ?? []
        return ChiefDebugReport(
            connection: store.map { String(describing: $0.connection) } ?? "not configured",
            me: store?.me?.displayName,
            transcriptCount: conversation.flatMap { id in store?.transcript(for: id).count } ?? 0,
            visibleRows: items.map { "\($0.label): \($0.value)" },
            frame: frame,
            snapshotPath: renderSnapshot()?.path(percentEncoded: false)
        )
    }

    private func renderSnapshot() -> URL? {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Layer coordinates are flipped relative to the bitmap.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-chief-\(UUID().uuidString.prefix(8)).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// The tab closed: stop the poll and the observation.
    public func close() {
        waitTask?.cancel()
        waitTask = nil
        binding?.stop()
        binding = nil
        store?.stop()
    }
}

/// What `debug.chief` reports for one Chief tab.
public struct ChiefDebugReport: Sendable {
    public var connection: String
    public var me: String?
    public var transcriptCount: Int
    /// The rows the transcript draws now, from its accessibility items (label: text).
    public var visibleRows: [String]
    public var frame: CGRect
    public var snapshotPath: String?
}
