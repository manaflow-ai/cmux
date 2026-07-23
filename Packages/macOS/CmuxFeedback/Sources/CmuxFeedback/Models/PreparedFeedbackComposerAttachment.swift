import Foundation

/// An attachment after upload preparation: re-encoded/optimized image data ready
/// to append to the multipart request body.
struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}

extension PreparedFeedbackComposerAttachment {
    var sanitizedMultipartFileName: String {
        // Remove every character that could break out of the quoted-string
        // `filename="..."` parameter: the quote itself, the backslash escape
        // character, and any control characters (CR/LF header injection).
        String(fileName.unicodeScalars.filter { scalar in
            scalar != "\"" && scalar != "\\" && CharacterSet.controlCharacters.contains(scalar) == false
        })
    }
}
