import AppKit
import CmuxNextDesign

/// A live preview above a horizontal filmstrip of mini previews, each in
/// its own theme's colors; the picked one is ringed.
struct ThemeFilmstrip: OnboardingScreenVariant {
    static let id = "theme.filmstrip"
    static let step = OnboardingModel.Step.theme
    static let name = "Filmstrip"
    static let summary = "Preview over a scrolling row of mini previews."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        let margin: CGFloat = 40
        let preview = ThemeBoundPreview(model: model)
        let strip = ThemeChoiceStack(model: model, orientation: .horizontal, spacing: 8) { ThemeTile(size: NSSize(width: 120, height: 76)) }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        SystemScrollers.follow(scroll)
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        // The strip scrolls under the panel's edges; at rest the first ring
        // sits 4 pt outside the margin so its tile lines up with the preview.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: margin - 4, bottom: 0, right: margin - 4)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(strip)
        scroll.documentView = document
        let body = NSView()
        for view in [preview, scroll] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: body.topAnchor), preview.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: body.trailingAnchor), preview.heightAnchor.constraint(equalToConstant: 132),
            scroll.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: -margin),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: margin),
            scroll.heightAnchor.constraint(equalTo: document.heightAnchor),
            document.heightAnchor.constraint(equalTo: strip.heightAnchor),
            strip.leadingAnchor.constraint(equalTo: document.leadingAnchor), strip.topAnchor.constraint(equalTo: document.topAnchor),
            strip.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        var style = OnboardingScaffold.Style()
        style.margin = margin
        style.titleTop = 44
        style.bodyGap = 20
        return OnboardingScaffold.make(title: ThemeVariantStrings.titleLook, subtitle: ThemeVariantStrings.sentenceLive,
                                       body: body, context: context, style: style)
    }
}
