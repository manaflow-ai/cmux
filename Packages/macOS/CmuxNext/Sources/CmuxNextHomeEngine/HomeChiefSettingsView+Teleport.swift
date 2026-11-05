import AppKit
import CmuxNextDesign

/// The Runs On row (Chief teleport): where this Mac's Chief runs, as the location chip whose
/// Teleport menu moves it (the Home header shows no location chip, cmux issue 36047). Shown only for the Chief that
/// `cmux chief move` moves, this Mac's default one, wherever it runs now.
extension HomeChiefSettingsView {
    func addTeleportRow() {
        teleportRow.orientation = .vertical
        teleportRow.alignment = .leading
        teleportRow.isHidden = true
        teleportRow.setAccessibilityIdentifier("cmux.home.chief.teleportRow")
        addFullWidth(teleportRow)
        stack.setCustomSpacing(Metrics.space4, after: teleportRow)
    }

    /// Shows the Runs On row with `chip`; nil hides it.
    public func showTeleport(_ chip: ChiefTeleportChip?) {
        let shown = teleportRow.arrangedSubviews.first.flatMap { ($0 as? NSStackView)?.arrangedSubviews.last }
        guard shown !== chip else { return }
        for view in teleportRow.arrangedSubviews { view.removeFromSuperview() }
        if let chip {
            let row = Self.row(ChiefTeleportStrings.row, chip)
            row.translatesAutoresizingMaskIntoConstraints = false
            teleportRow.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: teleportRow.widthAnchor).isActive = true
        }
        teleportRow.isHidden = chip == nil
        onResize()
    }
}
