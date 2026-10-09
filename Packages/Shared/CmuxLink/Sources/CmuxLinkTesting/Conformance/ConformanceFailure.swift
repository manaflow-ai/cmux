/// A broken promise found by `LinkConformanceSuite`.
public struct ConformanceFailure: Error, Sendable, CustomStringConvertible {
    public var harness: String
    public var testCase: ConformanceCase?
    public var message: String

    public init(harness: String, testCase: ConformanceCase?, message: String) {
        self.harness = harness
        self.testCase = testCase
        self.message = message
    }

    public var description: String {
        "[\(harness)] \(testCase?.rawValue ?? "setup"): \(message)"
    }
}
