import Foundation

struct BrowserErrorPageContent {
    let title: String
    let message: String
    let permitsSSLBypass: Bool

    init(title: String, message: String, permitsSSLBypass: Bool) {
        self.title = title
        self.message = message
        self.permitsSSLBypass = permitsSSLBypass
    }

    init(error: NSError, failedURL: String) {
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            title = String(localized: "browser.error.cantReach.title", defaultValue: "Can\u{2019}t reach this page")
            if failedURL.isEmpty {
                message = String(localized: "browser.error.cantReach.messageSite", defaultValue: "The site refused to connect. Check that a server is running on this address.")
            } else {
                message = String(localized: "browser.error.cantReach.messageURL", defaultValue: "\(failedURL) refused to connect. Check that a server is running on this address.")
            }
            permitsSSLBypass = false
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            title = String(localized: "browser.error.noInternet", defaultValue: "No internet connection")
            message = String(localized: "browser.error.checkNetwork", defaultValue: "Check your network connection and try again.")
            permitsSSLBypass = false
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            title = String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
            message = String(localized: "browser.error.invalidCertificate", defaultValue: "The certificate for this site is invalid.")
            permitsSSLBypass = true
        default:
            title = String(localized: "browser.error.cantOpen.title", defaultValue: "Can\u{2019}t open this page")
            message = String(localized: "browser.error.cantOpen.message", defaultValue: "The page could not be opened. Check the address and try again.")
            permitsSSLBypass = false
        }
    }
}
