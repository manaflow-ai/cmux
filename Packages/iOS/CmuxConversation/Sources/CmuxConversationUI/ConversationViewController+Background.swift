#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Conversation backgrounds (iOS 26 Messages): the shared background behind
/// the transcript, the light or dark style it implies, and the gallery.
extension ConversationViewController {
    /// Whether the system scroll pocket covers the header over a background.
    static var usesSystemTopPocket: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func installBackground() {
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(backdropView, at: 0)
        applyBackground(animated: false)
    }

    /// Shows the store's background and derives the transcript's style from
    /// its luminance (ChatKit `contentDerivedUserInterfaceStyleForLuminance`):
    /// a dark background turns timestamps, notices, sender names, the header
    /// and the composer light, whatever the system appearance.
    func applyBackground(animated: Bool) {
        let background = store.background
        backdropView.show(background, animated: animated && view.window != nil)
        if let background {
            traitOverrides.userInterfaceStyle = background.prefersDarkContent ? .dark : .light
            traitOverrides.isOverConversationBackdrop = true
        } else {
            if traitOverrides.contains(UITraitUserInterfaceStyle.self) { traitOverrides.remove(UITraitUserInterfaceStyle.self) }
            if traitOverrides.contains(ConversationBackdropTrait.self) { traitOverrides.remove(ConversationBackdropTrait.self) }
        }
        collectionView.backgroundColor = background == nil ? ConversationTheme.background : .clear
        // A color wash suits only the plain system background. Over any
        // conversation background Messages uses the system pocket (ChatKit
        // sets its color to nil); before iOS 26 the transcript is masked
        // with the same ramp instead.
        topEdgeFade.isHidden = background != nil
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = background == nil
        }
        collectionView.topFadeHeaderBottom = background == nil || Self.usesSystemTopPocket
            ? nil : header.frame.maxY - collectionView.frame.minY
        detailsOverlay?.background = background
    }

    /// The details panel's "Backgrounds" row (hidden when the backend has none).
    func configureBackgroundRow(_ overlay: ConversationDetailsOverlay) {
        overlay.background = store.background
        guard store.supportsBackgrounds else { return }
        overlay.onEditBackground = { [weak self] in self?.presentBackgroundPicker() }
    }

    /// Opens the background gallery as a sheet; "Set" applies the choice for
    /// everyone in the conversation. The details row and the lab call this.
    public func presentBackgroundPicker() {
        guard store.supportsBackgrounds, presentedViewController == nil else { return }
        view.endEditing(true)
        let picker = ConversationBackgroundPickerViewController(current: store.background)
        picker.onSet = { [weak self] choice in self?.applyBackgroundChoice(choice) }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    func applyBackgroundChoice(_ choice: ConversationBackgroundChoice) {
        let rejected: @MainActor (ConversationBackendError) -> Void = { [weak self] _ in
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self?.applyBackground(animated: true)
        }
        switch choice {
        case .none:
            store.setBackground(nil, rejected: rejected)
        case let .draft(draft):
            store.setBackground(draft, rejected: rejected)
        case let .photo(photo):
            store.setBackgroundPhoto(photo.data, mimeType: photo.mimeType, width: photo.width, height: photo.height, luminance: photo.luminance, rejected: rejected)
        }
    }
}
#endif

#if canImport(UIKit) && DEBUG
/// Lab verbs for headless runs: each reaches the same entry point as the
/// details row, the gallery tiles and "Set".
extension ConversationViewController {
    public func backgroundLabCommand(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let picker = (presentedViewController as? UINavigationController)?.viewControllers.first as? ConversationBackgroundPickerViewController
        switch parts.first {
        case "info":
            openInfo()
            return "ok"
        case "details":
            // The details panel's "Backgrounds" row.
            guard let overlay = detailsOverlay, let open = overlay.onEditBackground else { return "error no row" }
            open()
            return "ok"
        case "picker":
            presentBackgroundPicker()
            return "ok"
        case "category":
            guard let picker else { return "error no picker" }
            return picker.labSelectCategory(argument) ? "ok" : "error unknown category"
        case "look":
            guard let picker else { return "error no picker" }
            return picker.labSelectLook(argument) ? "ok" : "error unknown look"
        case "color":
            guard let picker else { return "error no picker" }
            return picker.labSelectColor(argument) ? "ok" : "error bad color"
        case "set":
            guard let picker else { return "error no picker" }
            picker.labCommit()
            return "ok"
        case "state":
            let style = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            guard let background = store.background else { return "none style=\(style)" }
            return "\(background.kind.rawValue) look=\(background.look ?? "-") L=\(String(format: "%.3f", background.luminance)) style=\(style) by=\(background.setBy ?? "-") paused=\(backdropView.backdrop.isMotionPaused) image=\(backdropView.backdrop.image != nil) contrast=\(backdropView.backdrop.increasesContrast) \(backdropView.backdrop.debugSummary) superview=\(backdropView.superview != nil) index=\(view.subviews.firstIndex(of: backdropView) ?? -1) alpha=\(backdropView.alpha)"
        default:
            return "error unknown verb"
        }
    }
}

extension ConversationBackgroundPickerViewController {
    func labSelectCategory(_ name: String) -> Bool {
        if name == "none" {
            selectCategoryFromLab(nil)
            return true
        }
        guard let kind = ConversationBackground.Kind(rawValue: name) else { return false }
        selectCategoryFromLab(kind)
        return true
    }

    func labSelectLook(_ id: String) -> Bool {
        guard let look = ConversationBackgroundLook.named(id) else { return false }
        selectLookFromLab(look)
        return true
    }

    func labSelectColor(_ hex: String) -> Bool {
        guard let (r, g, b) = ConversationBackground.rgb(hex: hex) else { return false }
        selectColorFromLab(UIColor(red: r, green: g, blue: b, alpha: 1))
        return true
    }
}
#endif
