import CmuxNotifications
import Testing

@Suite struct RetiredMemoryPressureNoticeTests {
    @Test func matchesEachRetiredWarningInEveryShippedLocale() {
        #expect(RetiredMemoryPressureNotice.matches(
            title: "cmux is under critical memory pressure",
            subtitle: "Hidden renderers and browsers were released"
        ))
        #expect(RetiredMemoryPressureNotice.matches(
            title: "cmux 正处于严重内存压力下",
            subtitle: "已释放隐藏的渲染器和浏览器"
        ))
        #expect(RetiredMemoryPressureNotice.matches(
            title: "cmux is using substantial aggregate memory",
            subtitle: "Idle agent surfaces may be hibernated"
        ))
        #expect(RetiredMemoryPressureNotice.matches(
            title: "cmux 全体のメモリ使用量が大きくなっています",
            subtitle: "アイドル状態のエージェントサーフェスを休止する場合があります"
        ))
    }

    @Test func keepsNotificationsThatOnlyReuseOneString() {
        #expect(!RetiredMemoryPressureNotice.matches(
            title: "cmux is using substantial aggregate memory",
            subtitle: "User message"
        ))
        #expect(!RetiredMemoryPressureNotice.matches(
            title: "Build finished",
            subtitle: "Hidden renderers and browsers were released"
        ))
        // A title from one locale with another locale's subtitle was never posted.
        #expect(!RetiredMemoryPressureNotice.matches(
            title: "cmux is under critical memory pressure",
            subtitle: "已释放隐藏的渲染器和浏览器"
        ))
    }
}
