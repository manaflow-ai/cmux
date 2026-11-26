import Foundation

extension URLAuthenticationChallenge {
    var isBrowserClientCertificateChallenge: Bool {
        protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
    }
}
