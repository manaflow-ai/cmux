import CmuxCloudImagePaste
import Foundation

extension CloudImagePasteError {
    var localizedMessage: String {
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
        case .tooManyImages:
            return String(localized: "cloud.imagePaste.tooManyImages", defaultValue: "Select up to eight images at a time.")
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

}
