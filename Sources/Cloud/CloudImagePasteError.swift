import Foundation

enum CloudImagePasteError: Error, LocalizedError, Equatable {
    case unavailable
    case unsupported
    case sizeLimit
    case unsupportedType
    case capacity
    case storage
    case timedOut
    case deliveryUncertain
    case useTerminal
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "cloud.imagePaste.unavailable", defaultValue: "The Cloud terminal link is unavailable. Reconnect the terminal, then paste the image again.")
        case .unsupported:
            return String(localized: "cloud.imagePaste.unsupported", defaultValue: "This Cloud daemon cannot receive clipboard images. Update cmux-tui on the machine and reconnect the terminal.")
        case .sizeLimit:
            return String(localized: "cloud.imagePaste.sizeLimit", defaultValue: "The image exceeds the 20 MiB limit. Resize it and try again.")
        case .unsupportedType:
            return String(localized: "cloud.imagePaste.unsupportedType", defaultValue: "Cloud image paste accepts PNG, JPEG, GIF, and WebP files. Copy a supported image and try again.")
        case .capacity:
            return String(localized: "cloud.imagePaste.capacity", defaultValue: "Cloud temporary image storage is full. Wait ten minutes for previous images to expire, then try again.")
        case .storage:
            return String(localized: "cloud.imagePaste.storage", defaultValue: "The image could not be stored. Check the machine’s available disk space and copy the image again.")
        case .timedOut:
            return String(localized: "cloud.imagePaste.timedOut", defaultValue: "The image transfer timed out. Reconnect the Cloud terminal and try again.")
        case .deliveryUncertain:
            return String(localized: "cloud.imagePaste.deliveryUncertain", defaultValue: "The link closed before image paste was confirmed. Check the agent for an attachment before pasting again.")
        case .useTerminal:
            return String(localized: "cloud.imagePaste.useTerminal", defaultValue: "Paste this image directly into the Cloud terminal. Image attachments in the command buffer are not supported yet.")
        case .busy:
            return String(localized: "cloud.imagePaste.busy", defaultValue: "An image transfer is already in progress. Wait for it to finish or cancel it before pasting again.")
        }
    }

    init(serverCode: String?) {
        switch serverCode {
        case "image-type-rejected": self = .unsupportedType
        case "image-size-limit": self = .sizeLimit
        case "image-capacity-limit": self = .capacity
        case "image-storage-unavailable": self = .storage
        case "image-paste-uncertain", "image-already-pasted": self = .deliveryUncertain
        case "image-upload-expired": self = .timedOut
        default: self = .unavailable
        }
    }
}
