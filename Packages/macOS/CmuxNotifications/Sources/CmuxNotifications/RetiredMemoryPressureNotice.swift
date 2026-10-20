/// cmux's own memory-pressure warning, which builds before
/// manaflow-ai/cmux#12667 recorded as a workspace-level notification on
/// whichever workspace was selected.
///
/// cmux no longer posts it and nothing else owns or clears it, so a persisted
/// copy would otherwise stay as that workspace's sidebar subtitle across every
/// relaunch (manaflow-ai/cmux#21847). Session restore drops records that match.
/// The title and subtitle are matched as the exact pair each shipped locale
/// used, so a user notification that reuses one of the strings is kept.
public enum RetiredMemoryPressureNotice {
    /// Whether a workspace-level notification is the retired memory-pressure warning.
    public static func matches(title: String, subtitle: String) -> Bool {
        titlesBySubtitle[subtitle]?.contains(title) ?? false
    }

    private static let titlesBySubtitle: [String: Set<String>] = Dictionary(
        (critical + aggregate).map { ($0.subtitle, Set([$0.title])) },
        uniquingKeysWith: { $0.union($1) }
    )

    /// `memoryPressure.critical.title` and `.subtitle`, as shipped per locale.
    private static let critical: [(title: String, subtitle: String)] = [
        ("cmux تحت ضغط ذاكرة حرج", "تم تحرير العارضات والمتصفحات المخفية"), // ar
        ("cmux je pod kritičnim memorijskim pritiskom", "Skriveni rendereri i preglednici su oslobođeni"), // bs
        ("cmux er under kritisk hukommelsespres", "Skjulte renderere og browsere blev frigivet"), // da
        ("cmux steht unter kritischem Speicherdruck", "Ausgeblendete Renderer und Browser wurden freigegeben"), // de
        ("cmux is under critical memory pressure", "Hidden renderers and browsers were released"), // en
        ("cmux está bajo presión crítica de memoria", "Se liberaron renderizadores y navegadores ocultos"), // es
        ("cmux subit une pression mémoire critique", "Les moteurs de rendu et navigateurs masqués ont été libérés"), // fr
        ("cmux è sotto pressione di memoria critica", "Renderer e browser nascosti sono stati rilasciati"), // it
        ("cmux に重大なメモリプレッシャーがかかっています", "非表示のレンダラーとブラウザを解放しました"), // ja
        ("cmux에 심각한 메모리 압박이 있습니다", "숨겨진 렌더러와 브라우저가 해제되었습니다"), // ko
        ("cmux er under kritisk minnepress", "Skjulte renderere og nettlesere ble frigitt"), // nb
        ("cmux jest pod krytyczną presją pamięci", "Ukryte renderery i przeglądarki zostały zwolnione"), // pl
        ("cmux está sob pressão crítica de memória", "Renderizadores e navegadores ocultos foram liberados"), // pt-BR
        ("cmux испытывает критическую нехватку памяти", "Скрытые рендереры и браузеры были освобождены"), // ru
        ("cmux อยู่ภายใต้แรงกดดันหน่วยความจำระดับวิกฤต", "ปล่อยตัวเรนเดอร์และเบราว์เซอร์ที่ซ่อนอยู่แล้ว"), // th
        ("cmux kritik bellek baskısı altında", "Gizli işleyiciler ve tarayıcılar serbest bırakıldı"), // tr
        ("cmux перебуває під критичним тиском пам’яті", "Приховані рендерери та браузери звільнено"), // uk
        ("cmux 正处于严重内存压力下", "已释放隐藏的渲染器和浏览器"), // zh-Hans
        ("cmux 正處於嚴重記憶體壓力下", "已釋放隱藏的轉譯器和瀏覽器"), // zh-Hant
    ]

    /// `memoryPressure.aggregate.title` and `.subtitle`, as shipped per locale.
    /// Locales without a translation fell back to English.
    private static let aggregate: [(title: String, subtitle: String)] = [
        ("يستخدم cmux ذاكرة إجمالية كبيرة", "قد يتم إدخال أسطح الوكلاء الخاملة في وضع السبات"), // ar
        ("cmux verbraucht erheblichen Gesamtspeicher", "Agent-Oberflächen im Leerlauf können in den Ruhezustand versetzt werden"), // de
        ("cmux is using substantial aggregate memory", "Idle agent surfaces may be hibernated"), // en
        ("cmux está utilizando una cantidad considerable de memoria agregada", "Las superficies inactivas del agente pueden hibernarse"), // es
        ("cmux utilise une quantité substantielle de mémoire globale", "Les surfaces d’affichage d’agent inactives peuvent être mises en veille prolongée"), // fr
        ("cmux 全体のメモリ使用量が大きくなっています", "アイドル状態のエージェントサーフェスを休止する場合があります"), // ja
        ("cmux가 상당한 양의 총 메모리를 사용하고 있습니다", "유휴 에이전트 화면이 최대 절전 모드로 전환될 수 있습니다"), // ko
        ("cmux 占用的总内存较大", "空闲的代理表面可能会被休眠"), // zh-Hans
        ("cmux 正在使用大量的彙總記憶體", "閒置的 Agent 介面可能會進入休眠狀態"), // zh-Hant
    ]
}
