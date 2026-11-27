public import AppKit

/// The backend a cmux Sign In signs in to, said under the button (Leo: "why is the stuff so weird to
/// log in to dev builds?"): "Signs in to cmux.com" on production, "Signs in to Development backend ·
/// dev-abc.cmux.dev" on a dev build. Rust names the backend (`backend_label`, the app's
/// `CloudConfiguration.backendLabel`); ``backendLine(kind:title:detail:)`` says it in the person's
/// language, and each place that offers the cmux sign-in passes that line to the button.
extension SignInButton {
    /// The line for Rust's backend label: `kind` (`production`, `development`, `local`) picks the
    /// localized name (`title` for production, where it is a name, and for a kind this build does not
    /// know), then the detail after a middle dot.
    public nonisolated static func backendLine(kind: String, title: String, detail: String?) -> String {
        let name = switch kind {
        case "development": String(localized: "signIn.backend.development", defaultValue: "Development backend", bundle: .module)
        case "local": String(localized: "signIn.backend.local", defaultValue: "Local backend", bundle: .module)
        default: title
        }
        let target = detail.map { "\(name) · \($0)" } ?? name
        return String(format: String(localized: "signIn.backend", defaultValue: "Signs in to %@", bundle: .module), target)
    }

    /// The identifier of the line under a Sign In button, so automation and tests find it.
    public static let backendLineIdentifier = NSUserInterfaceItemIdentifier("cmux.signIn.backend")

    /// This button with `line` under it, leading-aligned; the button alone when there is none.
    public func withBackendLine(_ line: String?) -> NSView {
        guard let label = Self.backendLineLabel(line) else { return self }
        let stack = NSStackView(views: [self, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// `line` as the small secondary label, for a place whose Sign In sits in a row of buttons (the line
    /// goes under the row); nil when there is none.
    public static func backendLineLabel(_ line: String?) -> NSView? {
        line.map { SignInBackendLabel($0) }
    }
}

/// The small secondary line under a Sign In button.
final class SignInBackendLabel: ChromeLabel {
    convenience init(_ line: String) {
        self.init(labelWithString: line)
        identifier = SignInButton.backendLineIdentifier
        font = Typography.caption
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { textColor = Palette.textSecondary }
    }
}
