import Foundation
import ObjectiveC
import PhotosUI
import UIKit

/// The key the picker controller keeps its ``PhotoPicker`` under.
nonisolated(unsafe) private var photoPickerAssociationKey: UInt8 = 0

/// A `PHPickerViewController` and its delegate.
///
/// The controller keeps this wrapper alive (an associated object: its
/// `delegate` is weak), so the app may hold only ``viewController``. Until the
/// app first reads ``viewController`` the wrapper holds the controller; after
/// that the app's reference (or the presentation) does, and the wrapper only
/// points at it, so the two do not keep each other alive.
@MainActor
final class PhotoPicker: NSObject, SystemUIPhotoPicker {
    /// The controller, held until the app takes it.
    private var heldUntilRead: PHPickerViewController?
    private weak var controller: PHPickerViewController?
    private let onPick: ([any SystemUIPhotoPick]) -> Void
    /// `.continuousAndOrdered`: every change is reported; the picker is
    /// embedded, not presented, so there is no swipe to dismiss.
    private let isContinuous: Bool
    /// A non-continuous pick was reported (Add, Cancel or a swipe down).
    private var finished = false

    init(
        filter: SystemUIPhotoFilter,
        selectionLimit: Int,
        selection: SystemUIPhotoSelection,
        encoding: SystemUIPhotoEncoding,
        photoLibrary: Bool,
        preselectedAssetIdentifiers: [String],
        onPick: @escaping ([any SystemUIPhotoPick]) -> Void
    ) {
        var configuration = photoLibrary ? PHPickerConfiguration(photoLibrary: .shared()) : PHPickerConfiguration()
        switch filter {
        case .images:
            configuration.filter = .images
        case .imagesAndVideos:
            configuration.filter = .any(of: [.images, .videos])
        }
        configuration.selectionLimit = selectionLimit
        switch selection {
        case .standard:
            configuration.selection = .default
        case .ordered:
            configuration.selection = .ordered
        case .continuousAndOrdered:
            configuration.selection = .continuousAndOrdered
        }
        switch encoding {
        case .automatic:
            configuration.preferredAssetRepresentationMode = .automatic
        case .current:
            configuration.preferredAssetRepresentationMode = .current
        case .compatible:
            configuration.preferredAssetRepresentationMode = .compatible
        }
        // Preselection needs the photo library (asset identifiers).
        if photoLibrary {
            configuration.preselectedAssetIdentifiers = preselectedAssetIdentifiers
        }
        let controller = PHPickerViewController(configuration: configuration)
        self.heldUntilRead = controller
        self.controller = controller
        self.onPick = onPick
        self.isContinuous = selection == .continuousAndOrdered
        super.init()
        controller.delegate = self
        if !isContinuous {
            // A swipe down closes the sheet without calling the picker's
            // delegate; this reports it as a cancel.
            controller.presentationController?.delegate = self
        }
        objc_setAssociatedObject(controller, &photoPickerAssociationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    nonisolated var viewController: UIViewController {
        MainActor.assumeIsolated {
            if let held = heldUntilRead {
                heldUntilRead = nil
                return held
            }
            // The app let the controller go and asks again: a placeholder
            // rather than a crash (the contract has no optional here).
            return controller ?? UIViewController()
        }
    }

    nonisolated func deselectAssets(withIdentifiers identifiers: [String]) {
        MainActor.assumeIsolated {
            controller?.deselectAssets(withIdentifiers: identifiers)
        }
    }

    fileprivate func deliver(_ picks: [any SystemUIPhotoPick]) {
        if isContinuous {
            onPick(picks)
            return
        }
        guard !finished else { return }
        finished = true
        onPick(picks)
    }
}

extension PhotoPicker: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let picks: [any SystemUIPhotoPick] = results.map {
            PhotoPick(itemProvider: $0.itemProvider, assetIdentifier: $0.assetIdentifier)
        }
        MainActor.assumeIsolated {
            deliver(picks)
        }
    }
}

extension PhotoPicker: UIAdaptivePresentationControllerDelegate {
    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated {
            deliver([])
        }
    }
}

/// One `PHPickerResult`.
final class PhotoPick: NSObject, SystemUIPhotoPick {
    let itemProvider: NSItemProvider
    let assetIdentifier: String?

    init(itemProvider: NSItemProvider, assetIdentifier: String?) {
        self.itemProvider = itemProvider
        self.assetIdentifier = assetIdentifier
    }
}
