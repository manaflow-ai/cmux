/// Mutable sendable test fixture for a synchronously sampled font percentage.
final class MutableFontMagnificationPercent:
    @unchecked Sendable {
    var value: Int

    init(_ value: Int) {
        self.value = value
    }
}
