#if canImport(UIKit)
import CmuxConversationGeometry
import PhotosUI
import UIKit

/// Messages' Photos drawer: a real sheet (`AppCardContainerViewController`,
/// a page sheet with a custom "keyboard" detent the keyboard's height and
/// the large detent; the keyboard detent selected and undimmed, grabber
/// shown). At the keyboard detent it floats inset in the keyboard's place
/// with the composer on its top and shows the three-column grid; dragged
/// up it fills the screen, covers the composer, dims the conversation and
/// shows the system photo picker's chrome ("Select up to 50 items", Photos
/// and Collections); dragged down it closes.
@MainActor
final class ConversationPhotoSheetController: UIViewController, PHPickerViewControllerDelegate, UISheetPresentationControllerDelegate {
    static let keyboardDetent = UISheetPresentationController.Detent.Identifier("keyboard")

    /// The selection changed: picked asset identifiers in selection order.
    var onSelection: (([String]) -> Void)?
    /// The sheet closed from its own drag.
    var onDismiss: (() -> Void)?
    private let grid = ConversationPhotoGridView()
    /// The full picker, shown at the large detent.
    private var picker: PHPickerViewController?
    /// The grabber's strip over the picker: the picker draws in another
    /// process and keeps the sheet's drag from starting on its top edge.
    private let grabberStrip = UIView()
    var selection: [String] { grid.selectedAssetIDs }

    /// UIKit's large detent on iOS 27; 10 pt shorter on iOS 26, as
    /// Messages' (same identifier, so the picker swap keys off it).
    private static var largeDetent: UISheetPresentationController.Detent {
        if #available(iOS 27.0, *) { return .large() }
        return .custom(identifier: .large) { context in
            PhotoDrawerGeometry.largeDetentValue(maximum: context.maximumDetentValue, leavesTopGap: true)
        }
    }

    init(sheetHeight: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [
                .custom(identifier: Self.keyboardDetent) { _ in PhotoDrawerGeometry.detentValue(height: sheetHeight) },
                Self.largeDetent,
            ]
            sheet.selectedDetentIdentifier = Self.keyboardDetent
            sheet.largestUndimmedDetentIdentifier = Self.keyboardDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Messages' sheet: the elevated system background (28,28,30 dark).
        view.backgroundColor = UIColor { traits in
            UIColor.systemBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .elevated })
        }
        view.accessibilityIdentifier = "conversation.photoDrawer"
        grid.frame = view.bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.onSelection = { [weak self] ids in self?.onSelection?(ids) }
        view.addSubview(grid)
        grabberStrip.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: PhotoDrawerGeometry.grabberStripHeight)
        grabberStrip.autoresizingMask = [.flexibleWidth]
        view.addSubview(grabberStrip)
    }

    func isSelected(assetID: String) -> Bool { selection.contains(assetID) }

    /// Drops one photo from the selection (its card preview was removed).
    func deselect(assetID: String) {
        guard selection.contains(assetID) else { return }
        grid.setSelection(selection.filter { $0 != assetID })
        picker?.deselectAssets(withIdentifiers: [assetID])
    }

    /// After a send: the badges clear.
    func clearSelection() {
        picker?.deselectAssets(withIdentifiers: selection)
        grid.clearSelection()
    }

    // MARK: Detents

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        if sheet.selectedDetentIdentifier == .large { showPicker() } else { hidePicker() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss?()
    }

    private func showPicker() {
        guard picker == nil else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = PhotoDrawerGeometry.selectionLimit(iOS27: ConversationComposerView.isIOS27)
        configuration.selection = .continuousAndOrdered
        configuration.preferredAssetRepresentationMode = .current
        configuration.preselectedAssetIdentifiers = selection
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        addChild(picker)
        picker.view.frame = view.bounds
        picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picker.view.alpha = 0
        view.insertSubview(picker.view, belowSubview: grabberStrip)
        picker.didMove(toParent: self)
        self.picker = picker
        UIView.animate(withDuration: 0.25) { picker.view.alpha = 1 }
    }

    private func hidePicker() {
        guard let picker else { return }
        self.picker = nil
        UIView.animate(withDuration: 0.25) {
            picker.view.alpha = 0
        } completion: { _ in
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            picker.removeFromParent()
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard picker === self.picker else { return }
        let ids = results.compactMap(\.assetIdentifier)
        grid.setSelection(ids)
        onSelection?(ids)
    }
}
#endif
