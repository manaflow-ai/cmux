// The Objective-C contract between the app and CmuxMobileSystemUI.framework.
//
// This file is compiled twice: into this module, which the app links, and
// into the framework (cmux-next-ios/project.yml lists it in the framework's
// sources), so the two images agree on it without the framework linking any
// package. It therefore holds only @objc protocols and @objc enums, never a
// class: a class here would be defined in both images. The Objective-C
// runtime matches the protocols by their explicit names, so the framework's
// principal class conforms to the app's `SystemUIProvider`.
//
// Only UIKit and Foundation types cross the boundary. Every UI and auth
// completion runs on the main thread; the store's completions run on any
// thread.
#if os(iOS)
public import Foundation
public import UIKit

/// The framework's principal class: every use of AuthenticationServices,
/// SafariServices, StoreKit, PhotosUI and QuickLook in the app.
@objc(CMXSystemUIProvider)
public protocol SystemUIProvider: NSObjectProtocol {
    // MARK: PhotosUI

    /// A `PHPickerViewController`. `onPick` runs on every pick: once when the
    /// person taps Add or Cancel (empty) or swipes the sheet away (empty), or
    /// on each change in ``SystemUIPhotoSelection/continuousAndOrdered``. The
    /// caller presents (or embeds) and dismisses it.
    /// - Parameters:
    ///   - photoLibrary: Whether the picker reads `PHPhotoLibrary.shared()`,
    ///     which gives each pick its ``SystemUIPhotoPick/assetIdentifier`` and
    ///     allows `preselectedAssetIdentifiers`.
    ///   - selectionLimit: The most items; 0 is no limit.
    func makePhotoPicker(
        filter: SystemUIPhotoFilter,
        selectionLimit: Int,
        selection: SystemUIPhotoSelection,
        encoding: SystemUIPhotoEncoding,
        photoLibrary: Bool,
        preselectedAssetIdentifiers: [String],
        onPick: @escaping ([any SystemUIPhotoPick]) -> Void
    ) -> any SystemUIPhotoPicker

    // MARK: QuickLook

    /// Whether QuickLook can preview the file at `url`.
    func canPreview(_ url: URL) -> Bool

    /// A `QLPreviewController` over `urls`, opened at `index`, with editing
    /// off.
    /// - Parameters:
    ///   - titles: One per URL; an empty string shows the file's own name.
    ///   - sourceView: The view the preview zooms from and back to, for the
    ///     item at an index, or nil for the default transition.
    ///   - onDismiss: Runs once the preview is gone.
    func makePreviewController(
        urls: [URL],
        titles: [String],
        index: Int,
        sourceView: ((Int) -> UIView?)?,
        onDismiss: (() -> Void)?
    ) -> UIViewController

    /// Points a controller from ``makePreviewController(urls:titles:index:sourceView:onDismiss:)``
    /// at new files and reloads it.
    func reloadPreviewController(_ controller: UIViewController, urls: [URL], titles: [String])

    // MARK: SafariServices

    /// An `SFSafariViewController` showing `url`.
    func makeSafariController(url: URL, entersReaderIfAvailable: Bool) -> UIViewController

    // MARK: AuthenticationServices

    /// Starts an `ASWebAuthenticationSession` presented from the active key
    /// window. `completion` gets the callback URL, or the session's error
    /// (its domain and code unchanged). Returns nil when the session would not
    /// start; `completion` then never runs.
    func startWebAuthentication(
        url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool,
        completion: @escaping (URL?, (any Error)?) -> Void
    ) -> (any SystemUICancellable)?

    /// Starts Sign in with Apple (full name and email scopes) presented from
    /// the active key window. `completion` gets the credential's identity
    /// token, or `unexpectedCredential` true when Apple returned another
    /// credential type, or the `ASAuthorizationController` error (its domain
    /// and code unchanged).
    func startAppleSignIn(
        completion: @escaping (_ identityToken: Data?, _ unexpectedCredential: Bool, _ error: (any Error)?) -> Void
    ) -> any SystemUICancellable

    // MARK: StoreKit

    /// StoreKit 2: products, purchases and transactions.
    var store: any SystemUIStore { get }

    /// `AppStore.showManageSubscriptions(in:)`: the App Store's subscription
    /// sheet. `completion` runs when it closes, with its error if it failed.
    func showManageSubscriptions(in scene: UIWindowScene, completion: @escaping ((any Error)?) -> Void)

    /// `Transaction.beginRefundRequest(for:in:)`: the App Store's refund
    /// sheet for one transaction.
    func beginRefundRequest(
        transactionID: UInt64,
        in scene: UIWindowScene,
        completion: @escaping (SystemUIRefundOutcome) -> Void
    )
}

// MARK: - PhotosUI

/// What a photo picker shows.
@objc(CMXSystemUIPhotoFilter)
public enum SystemUIPhotoFilter: Int, Sendable {
    case images
    case imagesAndVideos
}

/// `PHPickerConfiguration.Selection`.
@objc(CMXSystemUIPhotoSelection)
public enum SystemUIPhotoSelection: Int, Sendable {
    case standard
    case ordered
    case continuousAndOrdered
}

/// `PHPickerConfiguration.AssetRepresentationMode`.
@objc(CMXSystemUIPhotoEncoding)
public enum SystemUIPhotoEncoding: Int, Sendable {
    case automatic
    case current
    case compatible
}

/// One picked item (`PHPickerResult`).
@objc(CMXSystemUIPhotoPick)
public protocol SystemUIPhotoPick: NSObjectProtocol {
    var itemProvider: NSItemProvider { get }
    /// The asset's identifier, for a picker over the photo library.
    var assetIdentifier: String? { get }
}

/// A photo picker from ``SystemUIProvider/makePhotoPicker(filter:selectionLimit:selection:encoding:photoLibrary:preselectedAssetIdentifiers:onPick:)``.
@objc(CMXSystemUIPhotoPicker)
public protocol SystemUIPhotoPicker: NSObjectProtocol {
    /// The `PHPickerViewController`.
    var viewController: UIViewController { get }
    /// `PHPickerViewController.deselectAssets(withIdentifiers:)`.
    func deselectAssets(withIdentifiers identifiers: [String])
}

// MARK: - Sessions

/// A running system flow that can be torn down.
@objc(CMXSystemUICancellable)
public protocol SystemUICancellable: NSObjectProtocol {
    func cancel()
}

// MARK: - StoreKit

/// Why a store call failed; ``none`` when it did not.
@objc(CMXSystemUIStoreFailure)
public enum SystemUIStoreFailure: Int, Sendable {
    case none
    case productUnavailable
    case userCancelled
    case purchasesNotAllowed
    case network
    case system
}

/// `Product.PurchaseResult`, without its transaction.
@objc(CMXSystemUIPurchaseOutcome)
public enum SystemUIPurchaseOutcome: Int, Sendable {
    case completed
    case pending
    case userCancelled
}

/// `Transaction.RefundRequestStatus`, or a failed request.
@objc(CMXSystemUIRefundOutcome)
public enum SystemUIRefundOutcome: Int, Sendable {
    case success
    case userCancelled
    case error
}

/// A StoreKit `Product`.
@objc(CMXSystemUIStoreProduct)
public protocol SystemUIStoreProduct: NSObjectProtocol {
    var productID: String { get }
    var displayName: String { get }
    var productDescription: String { get }
    var displayPrice: String { get }
    /// The subscription period's unit, localized ("month"), for a subscription.
    var periodUnitName: String? { get }
    var price: NSDecimalNumber? { get }
    var currencyCode: String? { get }
    /// A yearly plan's price over twelve, formatted as its own price.
    var monthlyEquivalentDisplayPrice: String? { get }
}

/// A StoreKit `VerificationResult<Transaction>`. An unverified one carries
/// only its ids.
@objc(CMXSystemUIStoreTransaction)
public protocol SystemUIStoreTransaction: NSObjectProtocol {
    var isVerified: Bool { get }
    var transactionID: UInt64 { get }
    var productID: String { get }
    var jwsRepresentation: String { get }
    var appAccountToken: UUID? { get }
    /// `Production`, `Sandbox` or `Xcode`.
    var environment: String? { get }
}

/// StoreKit 2, for the app's `StoreKitClient`. The store holds each verified
/// transaction it hands out until ``finish(transactionID:completion:)``.
@objc(CMXSystemUIStore)
public protocol SystemUIStore: NSObjectProtocol {
    func products(
        identifiers: [String],
        completion: @escaping @Sendable ([any SystemUIStoreProduct], SystemUIStoreFailure) -> Void
    )
    func purchase(
        productID: String,
        appAccountToken: UUID,
        completion: @escaping @Sendable (SystemUIPurchaseOutcome, (any SystemUIStoreTransaction)?, SystemUIStoreFailure) -> Void
    )
    /// `Transaction.updates`, until the returned handle is cancelled.
    func observeTransactionUpdates(
        _ handler: @escaping @Sendable (any SystemUIStoreTransaction) -> Void
    ) -> any SystemUICancellable
    func unfinishedTransactions(completion: @escaping @Sendable ([any SystemUIStoreTransaction]) -> Void)
    func currentEntitlements(completion: @escaping @Sendable ([any SystemUIStoreTransaction]) -> Void)
    func syncWithAppStore(completion: @escaping @Sendable (SystemUIStoreFailure) -> Void)
    func storefrontCountryCode(completion: @escaping @Sendable (String?) -> Void)
    func finish(transactionID: UInt64, completion: @escaping @Sendable () -> Void)
    /// The signed `AppTransaction`'s environment: `Production`, `Sandbox`,
    /// or nil for Xcode testing or when StoreKit cannot tell.
    func appStoreEnvironment(completion: @escaping @Sendable (String?) -> Void)
}
#endif
