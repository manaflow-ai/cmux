actor DialDiagnosticRecorder {
    private var recordedLines: [String] = []

    func record(_ line: String) {
        recordedLines.append(line)
    }

    func lines() -> [String] {
        recordedLines
    }
}
