import SwiftUI

/// The empty app that hosts BillingStoreKitTests. StoreKit Testing serves a
/// configuration only to an app installed for development, so the tests run
/// inside this one; it does nothing on its own.
@main
struct BillingStoreKitHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
