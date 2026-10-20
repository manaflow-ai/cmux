import CmuxNotifications
import Testing

@Suite struct RetiredMemoryPressureNoticeTests {
    /// Every pair builds before #12667 could have recorded, copied independently from
    /// `memoryPressure.{critical,aggregate}.{title,subtitle}` at `0447a31a5dd6b^`.
    static let retiredPairs: [(locale: String, title: String, subtitle: String)] = [
        ("critical/ar", "cmux تحت ضغط ذاكرة حرج", "تم تحرير العارضات والمتصفحات المخفية"),
        ("critical/bs", "cmux je pod kritičnim memorijskim pritiskom", "Skriveni rendereri i preglednici su oslobođeni"),
        ("critical/da", "cmux er under kritisk hukommelsespres", "Skjulte renderere og browsere blev frigivet"),
        ("critical/de", "cmux steht unter kritischem Speicherdruck", "Ausgeblendete Renderer und Browser wurden freigegeben"),
        ("critical/en", "cmux is under critical memory pressure", "Hidden renderers and browsers were released"),
        ("critical/es", "cmux está bajo presión crítica de memoria", "Se liberaron renderizadores y navegadores ocultos"),
        ("critical/fr", "cmux subit une pression mémoire critique", "Les moteurs de rendu et navigateurs masqués ont été libérés"),
        ("critical/it", "cmux è sotto pressione di memoria critica", "Renderer e browser nascosti sono stati rilasciati"),
        ("critical/ja", "cmux に重大なメモリプレッシャーがかかっています", "非表示のレンダラーとブラウザを解放しました"),
        ("critical/ko", "cmux에 심각한 메모리 압박이 있습니다", "숨겨진 렌더러와 브라우저가 해제되었습니다"),
        ("critical/nb", "cmux er under kritisk minnepress", "Skjulte renderere og nettlesere ble frigitt"),
        ("critical/pl", "cmux jest pod krytyczną presją pamięci", "Ukryte renderery i przeglądarki zostały zwolnione"),
        ("critical/pt-BR", "cmux está sob pressão crítica de memória", "Renderizadores e navegadores ocultos foram liberados"),
        ("critical/ru", "cmux испытывает критическую нехватку памяти", "Скрытые рендереры и браузеры были освобождены"),
        ("critical/th", "cmux อยู่ภายใต้แรงกดดันหน่วยความจำระดับวิกฤต", "ปล่อยตัวเรนเดอร์และเบราว์เซอร์ที่ซ่อนอยู่แล้ว"),
        ("critical/tr", "cmux kritik bellek baskısı altında", "Gizli işleyiciler ve tarayıcılar serbest bırakıldı"),
        ("critical/uk", "cmux перебуває під критичним тиском пам’яті", "Приховані рендерери та браузери звільнено"),
        ("critical/zh-Hans", "cmux 正处于严重内存压力下", "已释放隐藏的渲染器和浏览器"),
        ("critical/zh-Hant", "cmux 正處於嚴重記憶體壓力下", "已釋放隱藏的轉譯器和瀏覽器"),
        ("aggregate/ar", "يستخدم cmux ذاكرة إجمالية كبيرة", "قد يتم إدخال أسطح الوكلاء الخاملة في وضع السبات"),
        ("aggregate/de", "cmux verbraucht erheblichen Gesamtspeicher", "Agent-Oberflächen im Leerlauf können in den Ruhezustand versetzt werden"),
        ("aggregate/en", "cmux is using substantial aggregate memory", "Idle agent surfaces may be hibernated"),
        ("aggregate/es", "cmux está utilizando una cantidad considerable de memoria agregada", "Las superficies inactivas del agente pueden hibernarse"),
        ("aggregate/fr", "cmux utilise une quantité substantielle de mémoire globale", "Les surfaces d’affichage d’agent inactives peuvent être mises en veille prolongée"),
        ("aggregate/ja", "cmux 全体のメモリ使用量が大きくなっています", "アイドル状態のエージェントサーフェスを休止する場合があります"),
        ("aggregate/ko", "cmux가 상당한 양의 총 메모리를 사용하고 있습니다", "유휴 에이전트 화면이 최대 절전 모드로 전환될 수 있습니다"),
        ("aggregate/zh-Hans", "cmux 占用的总内存较大", "空闲的代理表面可能会被休眠"),
        ("aggregate/zh-Hant", "cmux 正在使用大量的彙總記憶體", "閒置的 Agent 介面可能會進入休眠狀態"),
    ]

    @Test func retiredPairListCoversEveryShippedLocale() {
        #expect(Self.retiredPairs.count == 28)
    }

    @Test(arguments: retiredPairs.map { [$0.locale, $0.title, $0.subtitle] })
    func matchesRetiredWarning(_ pair: [String]) {
        #expect(RetiredMemoryPressureNotice().matches(title: pair[1], subtitle: pair[2]), "\(pair[0])")
    }

    @Test func keepsNotificationsThatOnlyReuseOneString() {
        #expect(!RetiredMemoryPressureNotice().matches(
            title: "cmux is using substantial aggregate memory",
            subtitle: "User message"
        ))
        #expect(!RetiredMemoryPressureNotice().matches(
            title: "Build finished",
            subtitle: "Hidden renderers and browsers were released"
        ))
        // A title from one locale with another locale's subtitle was never posted.
        #expect(!RetiredMemoryPressureNotice().matches(
            title: "cmux is under critical memory pressure",
            subtitle: "已释放隐藏的渲染器和浏览器"
        ))
    }
}
