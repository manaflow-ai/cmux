#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI
import UIKit

/// DEBUG only: the streamed page's key bar (`StreamKeyBar`, the production view) for
/// screenshots of its edge fade (`-cmux-mobile-recovery-gallery streamkeys|...`).
/// - `rows`: one bar per width (an iPhone SE / mini, this phone, a Pro Max drawn
///   scaled to fit) scrolled to its start, middle and end, plus a live bar to drag;
/// - `before`: the same rows with the fade off, as the bar was (keys cut at the edges);
/// - `keyboard`, `keyboard-before`: the bar where it really shows, above the keyboard
///   of a focused field, with the fade and without it.
/// Its keys go nowhere (no page).
public struct StreamKeyBarGallery: View {
    let scene: String

    public init(scene: String) {
        self.scene = scene
    }

    public var body: some View {
        if scene.hasPrefix("keyboard") {
            VStack {
                Text(verbatim: scene == "keyboard" ? "Streamed page key bar" : "Streamed page key bar, fade off").font(.headline)
                KeyBarField(fades: scene == "keyboard").frame(height: 44)
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("streamKeys.keyboard")
        } else {
            rows(fades: scene != "before")
        }
    }

    private func rows(fades: Bool) -> some View {
        GeometryReader { proxy in
            let screen = proxy.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    label(fades ? "Live (drag it), this phone" : "Live (drag it), this phone, fade off")
                    bar(width: screen, scale: 1, position: .start, fades: fades)
                        .accessibilityIdentifier("streamKeys.live")
                    ForEach(Self.widths(screen: screen), id: \.self) { width in
                        let scale = min(1, screen / width)
                        ForEach(Position.allCases, id: \.self) { position in
                            label("\(Int(width)) pt\(scale < 1 ? " at \(Int((scale * 100).rounded()))%" : ""), \(position.rawValue)\(fades ? "" : ", fade off")")
                            bar(width: width, scale: scale, position: position, fades: fades)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .accessibilityIdentifier("streamKeys.rows")
    }

    /// An iPhone SE / mini, this phone, a Pro Max.
    static func widths(screen: CGFloat) -> [CGFloat] {
        var widths: [CGFloat] = [375, screen.rounded(), 440]
        widths = widths.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return widths
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
    }

    private func bar(width: CGFloat, scale: CGFloat, position: Position, fades: Bool) -> some View {
        GalleryBar(position: position, fades: fades)
            .frame(width: width, height: 46)
            .scaleEffect(scale, anchor: .leading)
            .frame(width: width * scale, height: 46 * scale, alignment: .leading)
    }

    enum Position: String, CaseIterable {
        case start, middle, end
    }
}

/// One production key bar, scrolled to `position` once its content is laid out.
private struct GalleryBar: UIViewRepresentable {
    let position: StreamKeyBarGallery.Position
    let fades: Bool

    func makeUIView(context: Context) -> GalleryBarView {
        GalleryBarView(position: position, fades: fades)
    }

    func updateUIView(_ view: GalleryBarView, context: Context) {}
}

private final class GalleryBarView: UIView {
    let bar = StreamKeyBar(target: nil)
    let position: StreamKeyBarGallery.Position
    private var placedFor: CGSize = .zero
    private var contentSizeObservation: NSKeyValueObservation?

    init(position: StreamKeyBarGallery.Position, fades: Bool) {
        self.position = position
        super.init(frame: .zero)
        bar.scroll.fadesEdges = fades
        addSubview(bar)
        // The keys' width is known only after the bar's own layout pass: place the row then.
        contentSizeObservation = bar.scroll.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = bounds
        bar.layoutIfNeeded()
        let scroll = bar.scroll
        // Placed once per size, so a drag on the live bar is not undone.
        guard scroll.contentSize.width > 0, placedFor != scroll.contentSize else { return }
        placedFor = scroll.contentSize
        let end = max(0, scroll.contentSize.width - scroll.bounds.width)
        let x: CGFloat = switch position {
        case .start: 0
        case .middle: (end / 2).rounded()
        case .end: end
        }
        scroll.contentOffset = CGPoint(x: x, y: 0)
    }
}

/// A field whose keyboard carries the key bar, focused once it is in a window.
private struct KeyBarField: UIViewRepresentable {
    let fades: Bool

    func makeUIView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.borderStyle = .roundedRect
        field.placeholder = "Focused page field"
        let bar = StreamKeyBar(target: nil)
        bar.scroll.fadesEdges = fades
        field.inputAccessoryView = bar
        field.accessibilityIdentifier = "streamKeys.field"
        return field
    }

    func updateUIView(_ field: FocusingField, context: Context) {}
}

private final class FocusingField: UITextField {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }
}
#endif
