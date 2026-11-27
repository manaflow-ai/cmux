// CmuxMobileSystemUI.framework: every use of AuthenticationServices,
// SafariServices, StoreKit, PhotosUI and QuickLook in the app. The app embeds
// this framework but does not link it (cmux-next-ios/project.yml): linked, each
// of those system frameworks adds about 1.55 s before `main` on a cold launch
// (2.1 s together). CmuxMobileSystemUIBridge loads it on first use and reaches
// this principal class through SystemUIContract.swift, which both images
// compile. The framework links no package.
import Foundation
import QuickLook
import SafariServices
import UIKit

/// The framework's principal class (Info.plist `NSPrincipalClass`). The app
/// creates it with `init()` from any thread; every other call but ``store``
/// comes on the main thread, as the contract says.
@objc(CMXSystemUIProviderImplementation)
final class SystemUIProviderImplementation: NSObject, SystemUIProvider {
    /// Created with the provider; touches no UIKit.
    private let storeEngine = StoreEngine()

    override init() {
        super.init()
    }

    // MARK: PhotosUI

    func makePhotoPicker(
        filter: SystemUIPhotoFilter,
        selectionLimit: Int,
        selection: SystemUIPhotoSelection,
        encoding: SystemUIPhotoEncoding,
        photoLibrary: Bool,
        preselectedAssetIdentifiers: [String],
        onPick: @escaping ([any SystemUIPhotoPick]) -> Void
    ) -> any SystemUIPhotoPicker {
        let picker: PhotoPicker = MainActor.assumeIsolated {
            PhotoPicker(
                filter: filter,
                selectionLimit: selectionLimit,
                selection: selection,
                encoding: encoding,
                photoLibrary: photoLibrary,
                preselectedAssetIdentifiers: preselectedAssetIdentifiers,
                onPick: onPick
            )
        }
        return picker
    }

    // MARK: QuickLook

    func canPreview(_ url: URL) -> Bool {
        MainActor.assumeIsolated {
            QLPreviewController.canPreview(url as NSURL)
        }
    }

    func makePreviewController(
        urls: [URL],
        titles: [String],
        index: Int,
        sourceView: ((Int) -> UIView?)?,
        onDismiss: (() -> Void)?
    ) -> UIViewController {
        MainActor.assumeIsolated {
            PreviewController(urls: urls, titles: titles, index: index, sourceView: sourceView, onDismiss: onDismiss)
        }
    }

    func reloadPreviewController(_ controller: UIViewController, urls: [URL], titles: [String]) {
        MainActor.assumeIsolated {
            (controller as? PreviewController)?.reload(urls: urls, titles: titles)
        }
    }

    // MARK: SafariServices

    func makeSafariController(url: URL, entersReaderIfAvailable: Bool) -> UIViewController {
        MainActor.assumeIsolated {
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = entersReaderIfAvailable
            return SFSafariViewController(url: url, configuration: configuration)
        }
    }

    // MARK: AuthenticationServices

    func startWebAuthentication(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping (URL?, (any Error)?) -> Void
    ) -> (any SystemUICancellable)? {
        let session: WebAuthentication? = MainActor.assumeIsolated {
            WebAuthentication.start(
                url: url,
                callbackScheme: callbackScheme,
                prefersEphemeralSession: prefersEphemeralSession,
                completion: completion
            )
        }
        return session
    }

    func startAppleSignIn(
        completion: @escaping (_ identityToken: Data?, _ unexpectedCredential: Bool, _ error: (any Error)?) -> Void
    ) -> any SystemUICancellable {
        let flow: AppleSignIn = MainActor.assumeIsolated {
            AppleSignIn.start(completion: completion)
        }
        return flow
    }

    // MARK: StoreKit

    var store: any SystemUIStore { storeEngine }

    func showManageSubscriptions(in scene: UIWindowScene, completion: @escaping ((any Error)?) -> Void) {
        MainActor.assumeIsolated {
            StoreSheets.showManageSubscriptions(in: scene, completion: completion)
        }
    }

    func beginRefundRequest(
        transactionID: UInt64,
        in scene: UIWindowScene,
        completion: @escaping (SystemUIRefundOutcome) -> Void
    ) {
        MainActor.assumeIsolated {
            StoreSheets.beginRefundRequest(transactionID: transactionID, in: scene, completion: completion)
        }
    }
}
