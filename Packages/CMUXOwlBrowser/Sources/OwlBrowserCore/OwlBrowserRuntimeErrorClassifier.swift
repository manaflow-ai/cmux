import Foundation
import OwlMojoSystem

public enum OwlBrowserRuntimeErrorClassifier {
    public static func isPeerClosed(_ error: Error) -> Bool {
        if let mojoError = error as? MojoSystemError {
            return mojoError.isFailedPrecondition
        }
        return String(describing: error).contains("failed with result \(DynamicMojoSystem.mojoResultFailedPrecondition)")
    }
}
