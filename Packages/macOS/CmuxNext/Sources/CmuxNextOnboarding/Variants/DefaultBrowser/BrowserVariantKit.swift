import AppKit
import CmuxNextDesign

/// Where the default-browser claim stands, read once per render from the
/// step model. Every Default Browser variant draws from this one value.
struct BrowserClaimState: Equatable {
    var claimed: Bool
    var pending: Bool
    var error: String?
    /// The browser that opens links now (nil when macOS does not say).
    var current: String?

    @MainActor init(_ model: DefaultAppsStepModel) {
        claimed = model.isClaimed(.webBrowser)
        pending = model.pending.contains(.webBrowser)
        error = model.errors[.webBrowser]
        current = model.currentBrowserName
    }

    /// cmux is chosen or being chosen (radio, segment and checkbox state).
    var choosesCmux: Bool { claimed || pending }

    /// "Links open in Safari", or "Links open in cmux" once claimed.
    var headline: String {
        if claimed { return BrowserVariantStrings.linksOpenIn("cmux") }
        return current.map(BrowserVariantStrings.linksOpenIn) ?? BrowserVariantStrings.linksOpenElsewhere
    }

    /// Progress or refusal, else nil.
    var note: String? {
        if let error { return OnboardingStrings.systemRefused(error) }
        return pending ? OnboardingStrings.waiting : nil
    }

    /// One line for layouts with a single status label.
    var statusLine: String { note ?? headline }

    /// "Keep Safari" (or "Keep Current Browser").
    var keepTitle: String { current.map(BrowserVariantStrings.keep) ?? BrowserVariantStrings.keepCurrent }
}

/// A view that re-renders on every claim change. Subclasses build their
/// subviews, then call `startRendering()` last in their init.
class BrowserClaimView: NSView {
    let model: DefaultAppsStepModel
    private var loop: RenderLoop?

    init(model: DefaultAppsStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    final func startRendering() {
        loop = RenderLoop { [weak self] in
            guard let self else { return }
            self.apply(BrowserClaimState(self.model))
        }
    }

    /// Draw `state`. Called on the main actor, coalesced per turn.
    func apply(_ state: BrowserClaimState) {}

    /// Asks macOS to make cmux the browser (macOS confirms itself).
    @objc func requestClaim() { model.request(.webBrowser) }
}

/// Copy only the Default Browser variants use (OnboardingVariantsDefaultBrowser.xcstrings).
enum BrowserVariantStrings {
    static var openLinks: String {
        String(localized: "onboarding.v.browser.openLinks", defaultValue: "Open links in cmux",
               table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
    static var useCmux: String {
        String(localized: "onboarding.v.browser.useCmux", defaultValue: "Use cmux", table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
    static func keep(_ browser: String) -> String {
        String(format: String(localized: "onboarding.v.browser.keep", defaultValue: "Keep %@",
                              table: "OnboardingVariantsDefaultBrowser", bundle: .module), browser)
    }
    static var keepCurrent: String {
        String(localized: "onboarding.v.browser.keepCurrent", defaultValue: "Keep Current Browser",
               table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
    static func linksOpenIn(_ browser: String) -> String {
        String(format: String(localized: "onboarding.v.browser.linksOpenIn", defaultValue: "Links open in %@",
                              table: "OnboardingVariantsDefaultBrowser", bundle: .module), browser)
    }
    static var linksOpenElsewhere: String {
        String(localized: "onboarding.v.browser.linksOpenElsewhere", defaultValue: "Links open in another browser",
               table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
    static var opensLinksNow: String {
        String(localized: "onboarding.v.browser.opensLinksNow", defaultValue: "Opens links now",
               table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
    static var makeDefault: String {
        String(localized: "onboarding.v.browser.makeDefault", defaultValue: "Make Default",
               table: "OnboardingVariantsDefaultBrowser", bundle: .module)
    }
}

extension OnboardingFooter {
    /// Adds the footer to `root` along its bottom edge (`margin` on the sides).
    @discardableResult
    func pinBrowserFooter(in root: NSView, margin: CGFloat, bottom: CGFloat = 28) -> OnboardingFooter {
        root.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -bottom),
        ])
        return self
    }
}

extension NSButton {
    /// A glass button one size up, for screens built around one action.
    static func browserHeroButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = OnboardingControl.button(title, prominent: true, target: target, action: action)
        button.controlSize = .extraLarge
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

extension Glass {
    /// A glass panel whose content is pinned to its edges, so the content's
    /// constraints size the panel.
    static func browserVariantPanel(_ content: NSView, cornerRadius: CGFloat) -> NSGlassEffectView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let glass = makePanel(content: content, cornerRadius: cornerRadius)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        return glass
    }
}
