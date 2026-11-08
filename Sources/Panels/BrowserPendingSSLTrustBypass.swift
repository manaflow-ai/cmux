import Foundation

struct BrowserPendingSSLTrustBypass {
    let grant: BrowserSSLTrustGrant
    let request: URLRequest
    let expiresAt: Date
}
