actor IrxControlReleaseProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
