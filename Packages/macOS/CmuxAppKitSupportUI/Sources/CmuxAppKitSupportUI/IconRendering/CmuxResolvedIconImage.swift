public import AppKit

/// Native convenience view for an appearance-resolved cmux icon.
@MainActor
public final class CmuxResolvedIconImage: CmuxResolvedIconImageView {
    /// Creates and immediately applies an icon request.
    public init(request: CmuxResolvedIconRequest?) {
        super.init(frame: .zero)
        apply(request)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
