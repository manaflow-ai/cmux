import Foundation

extension Int {
    /// A variant's letter in the review tool (A, B, …; past Z, its 1-based number).
    var galleryLetter: String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return self < letters.count ? String(letters[self]) : "\(self + 1)"
    }
}
