/// How a window background image is scaled to the window.
///
/// The raw values are the `windowBackground.imageFit` strings accepted in
/// `cmux.json`, so they must not be renamed.
public enum WindowBackgroundImageFit: String, CaseIterable, Sendable {
    /// Scales the image, keeping its aspect ratio, until it covers the whole
    /// window. Edges that overflow are cropped.
    case cover

    /// Scales the image, keeping its aspect ratio, until it fits inside the
    /// window. Uncovered bands show the terminal background color.
    case contain

    /// Stretches the image to the window size, ignoring its aspect ratio.
    case stretch
}
