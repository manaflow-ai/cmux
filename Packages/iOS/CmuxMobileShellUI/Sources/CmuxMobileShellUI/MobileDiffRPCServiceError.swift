import Foundation

/// Internal protocol failure when a capped host response makes no retry progress.
enum MobileDiffRPCServiceError: Error {
    case nonProgressingTruncation
}
