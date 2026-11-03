import AppKit

// The omnibar's parts made on first use (#32909): the suggestion card's top and the trailing badges' stack.
extension AddressBarView {
    /// The card's top, under the pill, made when suggestions first show.
    func makeBackdrop() -> OmnibarCardTopView {
        let backdrop = OmnibarCardTopView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop, positioned: .below, relativeTo: pill)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -OmnibarStyle.cardSideOutset),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: OmnibarStyle.cardSideOutset),
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -OmnibarStyle.cardTopOutset),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        backdropIfMade = backdrop
        return backdrop
    }

    /// Adds the badges' stack at the bar's trailing end (`OmnibarTrailingBadges` makes it on first use).
    func installBadges(_ stack: NSStackView) {
        addSubview(stack)
        let toBadge = field.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -OmnibarStyle.textLeading)
        fieldToBadge = toBadge
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OmnibarStyle.chipLeading - 2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
