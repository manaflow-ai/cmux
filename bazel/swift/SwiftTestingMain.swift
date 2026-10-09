import Testing

@main
struct BazelPilotSwiftTestingMain {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
