import Foundation

extension AppDelegate {
    enum CmuxExternalURLAdmission: Equatable {
        case none
        case multipleRunLinks
        case multipleSSHLinks
        case multipleNonRunLinks
        case busy
        case route
    }
}
