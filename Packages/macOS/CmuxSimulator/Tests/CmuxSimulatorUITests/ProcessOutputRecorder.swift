actor ProcessOutputRecorder {
    private var value = ""

    func append(_ output: String) {
        value += output
    }

    func snapshot() -> String {
        value
    }
}
