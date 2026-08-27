internal import Foundation

protocol MobileCrashTransportSessionControlling: AnyObject {
    func makeSession() -> URLSession
    func invalidateAndCancel()
}
