export const AGENT_CHAT_LOCALES = [
  "en",
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "de",
  "es",
  "fr",
  "it",
  "da",
  "pl",
  "ru",
  "bs",
  "ar",
  "no",
  "pt-BR",
  "th",
  "tr",
  "km",
  "uk",
] as const;

export type AgentChatLocale = (typeof AGENT_CHAT_LOCALES)[number];
export type AgentChatTextKey =
  | "continuedNewChat"
  | "movedServingRoute"
  | "continueNewChat"
  | "continueElsewhere"
  | "transcriptViewRunning"
  | "transcriptViewIdle"
  | "answerInTerminal"
  | "agentMessageFrom"
  | "agentMessageQueued";
  | "loadingDiff"
  | "diffUnavailable"
  | "retryDiff";

const COPY: Record<AgentChatLocale, Record<AgentChatTextKey, string>> = {
  en: {
    continuedNewChat: "Continued in a new chat. Previous context is linked.",
    movedServingRoute: "Moved to another serving route. Conversation context was preserved.",
    continueNewChat: "Continue in new chat",
    continueElsewhere: "Continue elsewhere",
    transcriptViewRunning: "Working in the terminal · Esc to interrupt",
    transcriptViewIdle: "Sends to the agent in this terminal",
    answerInTerminal: "Answer in terminal",
    agentMessageFrom: "Message from {sender}",
    agentMessageQueued: "Waiting for the agent to take it",
    loadingDiff: "Loading diff…",
    diffUnavailable: "Couldn't load the diff. Try again.",
    retryDiff: "Retry",
  },
  ja: {
    continuedNewChat: "新しいチャットで続行しました。以前のコンテキストはリンクされています。",
    movedServingRoute: "別の配信ルートに移動しました。会話のコンテキストは保持されています。",
    continueNewChat: "新しいチャットで続行",
    continueElsewhere: "別の場所で続行",
    transcriptViewRunning: "ターミナルで作業中 · Esc で中断",
    transcriptViewIdle: "このターミナルのエージェントに送信します",
    answerInTerminal: "ターミナルで回答",
    agentMessageFrom: "{sender} からのメッセージ",
    agentMessageQueued: "エージェントが受け取るのを待っています",
    loadingDiff: "差分を読み込み中…",
    diffUnavailable: "差分を読み込めませんでした。もう一度お試しください。",
    retryDiff: "再試行",
  },
  "zh-CN": {
    continuedNewChat: "已在新聊天中继续。之前的上下文已关联。",
    movedServingRoute: "已切换到其他服务路由。对话上下文已保留。",
    continueNewChat: "在新聊天中继续",
    continueElsewhere: "在其他位置继续",
    transcriptViewRunning: "正在终端中工作 · 按 Esc 中断",
    transcriptViewIdle: "发送给此终端中的代理",
    answerInTerminal: "在终端中回答",
    agentMessageFrom: "来自 {sender} 的消息",
    agentMessageQueued: "正在等待代理接收",
    loadingDiff: "正在加载差异…",
    diffUnavailable: "无法加载差异。请重试。",
    retryDiff: "重试",
  },
  "zh-TW": {
    continuedNewChat: "已在新聊天中繼續。先前的內容已連結。",
    movedServingRoute: "已切換至其他服務路由。對話內容已保留。",
    continueNewChat: "在新聊天中繼續",
    continueElsewhere: "在其他位置繼續",
    transcriptViewRunning: "正在終端機中工作 · 按 Esc 中斷",
    transcriptViewIdle: "傳送給此終端機中的代理程式",
    answerInTerminal: "在終端機中回答",
    agentMessageFrom: "來自 {sender} 的訊息",
    agentMessageQueued: "正在等待代理程式接收",
    loadingDiff: "正在載入差異…",
    diffUnavailable: "無法載入差異。請再試一次。",
    retryDiff: "重試",
  },
  ko: {
    continuedNewChat: "새 채팅에서 계속합니다. 이전 컨텍스트가 연결되어 있습니다.",
    movedServingRoute: "다른 서비스 경로로 이동했습니다. 대화 컨텍스트는 유지되었습니다.",
    continueNewChat: "새 채팅에서 계속",
    continueElsewhere: "다른 곳에서 계속",
    transcriptViewRunning: "터미널에서 작업 중 · Esc로 중단",
    transcriptViewIdle: "이 터미널의 에이전트에게 보냅니다",
    answerInTerminal: "터미널에서 답변",
    agentMessageFrom: "{sender}의 메시지",
    agentMessageQueued: "에이전트가 받기를 기다리는 중",
    loadingDiff: "변경 사항을 불러오는 중…",
    diffUnavailable: "변경 사항을 불러오지 못했습니다. 다시 시도하세요.",
    retryDiff: "다시 시도",
  },
  de: {
    continuedNewChat: "In einem neuen Chat fortgesetzt. Der vorherige Kontext ist verknüpft.",
    movedServingRoute: "Auf eine andere Bereitstellungsroute gewechselt. Der Gesprächskontext wurde beibehalten.",
    continueNewChat: "In neuem Chat fortfahren",
    continueElsewhere: "Anderswo fortfahren",
    transcriptViewRunning: "Arbeitet im Terminal · Esc zum Unterbrechen",
    transcriptViewIdle: "Wird an den Agenten in diesem Terminal gesendet",
    answerInTerminal: "Im Terminal antworten",
    agentMessageFrom: "Nachricht von {sender}",
    agentMessageQueued: "Wartet darauf, dass der Agent sie abholt",
    loadingDiff: "Diff wird geladen…",
    diffUnavailable: "Der Diff konnte nicht geladen werden. Bitte erneut versuchen.",
    retryDiff: "Erneut versuchen",
  },
  es: {
    continuedNewChat: "Se continuó en un chat nuevo. El contexto anterior está vinculado.",
    movedServingRoute: "Se cambió a otra ruta de servicio. Se conservó el contexto de la conversación.",
    continueNewChat: "Continuar en un chat nuevo",
    continueElsewhere: "Continuar en otro lugar",
    transcriptViewRunning: "Trabajando en la terminal · Esc para interrumpir",
    transcriptViewIdle: "Se envía al agente de esta terminal",
    answerInTerminal: "Responder en la terminal",
    agentMessageFrom: "Mensaje de {sender}",
    agentMessageQueued: "Esperando a que el agente lo reciba",
    loadingDiff: "Cargando diferencias…",
    diffUnavailable: "No se pudieron cargar las diferencias. Inténtalo de nuevo.",
    retryDiff: "Reintentar",
  },
  fr: {
    continuedNewChat: "La conversation continue dans un nouveau chat. Le contexte précédent est lié.",
    movedServingRoute: "Passage à une autre route de service. Le contexte de la conversation a été conservé.",
    continueNewChat: "Continuer dans un nouveau chat",
    continueElsewhere: "Continuer ailleurs",
    transcriptViewRunning: "Travaille dans le terminal · Échap pour interrompre",
    transcriptViewIdle: "Envoyé à l’agent de ce terminal",
    answerInTerminal: "Répondre dans le terminal",
    agentMessageFrom: "Message de {sender}",
    agentMessageQueued: "En attente de sa prise en charge par l’agent",
    loadingDiff: "Chargement des différences…",
    diffUnavailable: "Impossible de charger les différences. Réessayez.",
    retryDiff: "Réessayer",
  },
  it: {
    continuedNewChat: "Continuazione in una nuova chat. Il contesto precedente è collegato.",
    movedServingRoute: "Passaggio a un altro percorso di servizio. Il contesto della conversazione è stato mantenuto.",
    continueNewChat: "Continua in una nuova chat",
    continueElsewhere: "Continua altrove",
    transcriptViewRunning: "Al lavoro nel terminale · Esc per interrompere",
    transcriptViewIdle: "Inviato all’agente di questo terminale",
    answerInTerminal: "Rispondi nel terminale",
    agentMessageFrom: "Messaggio da {sender}",
    agentMessageQueued: "In attesa che l’agente lo riceva",
    loadingDiff: "Caricamento delle differenze…",
    diffUnavailable: "Impossibile caricare le differenze. Riprova.",
    retryDiff: "Riprova",
  },
  da: {
    continuedNewChat: "Fortsat i en ny chat. Den tidligere kontekst er knyttet til.",
    movedServingRoute: "Flyttet til en anden serveringsrute. Samtalens kontekst blev bevaret.",
    continueNewChat: "Fortsæt i ny chat",
    continueElsewhere: "Fortsæt et andet sted",
    transcriptViewRunning: "Arbejder i terminalen · Esc for at afbryde",
    transcriptViewIdle: "Sendes til agenten i denne terminal",
    answerInTerminal: "Svar i terminalen",
    agentMessageFrom: "Besked fra {sender}",
    agentMessageQueued: "Venter på, at agenten tager imod den",
    loadingDiff: "Indlæser ændringer…",
    diffUnavailable: "Kunne ikke indlæse ændringerne. Prøv igen.",
    retryDiff: "Prøv igen",
  },
  pl: {
    continuedNewChat: "Kontynuowano w nowym czacie. Poprzedni kontekst jest połączony.",
    movedServingRoute: "Przeniesiono na inną trasę obsługi. Kontekst rozmowy został zachowany.",
    continueNewChat: "Kontynuuj w nowym czacie",
    continueElsewhere: "Kontynuuj gdzie indziej",
    transcriptViewRunning: "Pracuje w terminalu · Esc, aby przerwać",
    transcriptViewIdle: "Wysyłane do agenta w tym terminalu",
    answerInTerminal: "Odpowiedz w terminalu",
    agentMessageFrom: "Wiadomość od {sender}",
    agentMessageQueued: "Czeka, aż agent ją odbierze",
    loadingDiff: "Wczytywanie różnic…",
    diffUnavailable: "Nie udało się wczytać różnic. Spróbuj ponownie.",
    retryDiff: "Spróbuj ponownie",
  },
  ru: {
    continuedNewChat: "Продолжено в новом чате. Предыдущий контекст связан.",
    movedServingRoute: "Переключено на другой маршрут обслуживания. Контекст разговора сохранён.",
    continueNewChat: "Продолжить в новом чате",
    continueElsewhere: "Продолжить в другом месте",
    transcriptViewRunning: "Работает в терминале · Esc для прерывания",
    transcriptViewIdle: "Отправляется агенту в этом терминале",
    answerInTerminal: "Ответить в терминале",
    agentMessageFrom: "Сообщение от {sender}",
    agentMessageQueued: "Ждёт, пока агент его заберёт",
    loadingDiff: "Загрузка изменений…",
    diffUnavailable: "Не удалось загрузить изменения. Попробуйте ещё раз.",
    retryDiff: "Повторить",
  },
  bs: {
    continuedNewChat: "Nastavljeno u novom chatu. Prethodni kontekst je povezan.",
    movedServingRoute: "Prebačeno na drugu servisnu rutu. Kontekst razgovora je sačuvan.",
    continueNewChat: "Nastavi u novom chatu",
    continueElsewhere: "Nastavi drugdje",
    transcriptViewRunning: "Radi u terminalu · Esc za prekid",
    transcriptViewIdle: "Šalje se agentu u ovom terminalu",
    answerInTerminal: "Odgovori u terminalu",
    agentMessageFrom: "Poruka od {sender}",
    agentMessageQueued: "Čeka da je agent preuzme",
    loadingDiff: "Učitavanje razlika…",
    diffUnavailable: "Nije moguće učitati razlike. Pokušajte ponovo.",
    retryDiff: "Pokušaj ponovo",
  },
  ar: {
    continuedNewChat: "تمت المتابعة في محادثة جديدة. السياق السابق مرتبط.",
    movedServingRoute: "تم الانتقال إلى مسار خدمة آخر. تم الاحتفاظ بسياق المحادثة.",
    continueNewChat: "المتابعة في محادثة جديدة",
    continueElsewhere: "المتابعة في مكان آخر",
    transcriptViewRunning: "يعمل في الطرفية · Esc للمقاطعة",
    transcriptViewIdle: "يُرسل إلى الوكيل في هذه الطرفية",
    answerInTerminal: "أجب في الطرفية",
    agentMessageFrom: "رسالة من {sender}",
    agentMessageQueued: "بانتظار أن يستلمها الوكيل",
    loadingDiff: "جارٍ تحميل الفروقات…",
    diffUnavailable: "تعذّر تحميل الفروقات. حاول مرة أخرى.",
    retryDiff: "إعادة المحاولة",
  },
  no: {
    continuedNewChat: "Fortsatt i en ny chat. Tidligere kontekst er koblet til.",
    movedServingRoute: "Flyttet til en annen serveringsrute. Samtalekonteksten ble bevart.",
    continueNewChat: "Fortsett i ny chat",
    continueElsewhere: "Fortsett et annet sted",
    transcriptViewRunning: "Jobber i terminalen · Esc for å avbryte",
    transcriptViewIdle: "Sendes til agenten i denne terminalen",
    answerInTerminal: "Svar i terminalen",
    agentMessageFrom: "Melding fra {sender}",
    agentMessageQueued: "Venter på at agenten tar imot den",
    loadingDiff: "Laster endringer…",
    diffUnavailable: "Kunne ikke laste endringene. Prøv igjen.",
    retryDiff: "Prøv igjen",
  },
  "pt-BR": {
    continuedNewChat: "Continuado em um novo chat. O contexto anterior está vinculado.",
    movedServingRoute: "Movido para outra rota de atendimento. O contexto da conversa foi preservado.",
    continueNewChat: "Continuar em um novo chat",
    continueElsewhere: "Continuar em outro lugar",
    transcriptViewRunning: "Trabalhando no terminal · Esc para interromper",
    transcriptViewIdle: "Enviado ao agente deste terminal",
    answerInTerminal: "Responder no terminal",
    agentMessageFrom: "Mensagem de {sender}",
    agentMessageQueued: "Aguardando o agente receber",
    loadingDiff: "Carregando diferenças…",
    diffUnavailable: "Não foi possível carregar as diferenças. Tente novamente.",
    retryDiff: "Tentar novamente",
  },
  th: {
    continuedNewChat: "ดำเนินการต่อในแชทใหม่แล้ว โดยเชื่อมโยงบริบทก่อนหน้าไว้",
    movedServingRoute: "ย้ายไปยังเส้นทางการให้บริการอื่นแล้ว โดยยังคงบริบทการสนทนาไว้",
    continueNewChat: "ดำเนินการต่อในแชทใหม่",
    continueElsewhere: "ดำเนินการต่อที่อื่น",
    transcriptViewRunning: "กำลังทำงานในเทอร์มินัล · กด Esc เพื่อขัดจังหวะ",
    transcriptViewIdle: "ส่งถึงเอเจนต์ในเทอร์มินัลนี้",
    answerInTerminal: "ตอบในเทอร์มินัล",
    agentMessageFrom: "ข้อความจาก {sender}",
    agentMessageQueued: "กำลังรอให้เอเจนต์รับข้อความ",
    loadingDiff: "กำลังโหลดความแตกต่าง…",
    diffUnavailable: "ไม่สามารถโหลดความแตกต่างได้ โปรดลองอีกครั้ง",
    retryDiff: "ลองอีกครั้ง",
  },
  tr: {
    continuedNewChat: "Yeni bir sohbette devam edildi. Önceki bağlam bağlantılı.",
    movedServingRoute: "Başka bir hizmet rotasına geçildi. Konuşma bağlamı korundu.",
    continueNewChat: "Yeni sohbette devam et",
    continueElsewhere: "Başka yerde devam et",
    transcriptViewRunning: "Terminalde çalışıyor · Kesmek için Esc",
    transcriptViewIdle: "Bu terminaldeki ajana gönderilir",
    answerInTerminal: "Terminalde yanıtla",
    agentMessageFrom: "{sender} tarafından gönderilen mesaj",
    agentMessageQueued: "Aracının teslim alması bekleniyor",
    loadingDiff: "Farklar yükleniyor…",
    diffUnavailable: "Farklar yüklenemedi. Yeniden deneyin.",
    retryDiff: "Yeniden dene",
  },
  km: {
    continuedNewChat: "បានបន្តនៅក្នុងការជជែកថ្មី។ បរិបទមុនត្រូវបានភ្ជាប់។",
    movedServingRoute: "បានប្តូរទៅផ្លូវបម្រើផ្សេង។ បរិបទនៃការសន្ទនាត្រូវបានរក្សាទុក។",
    continueNewChat: "បន្តក្នុងការជជែកថ្មី",
    continueElsewhere: "បន្តនៅកន្លែងផ្សេង",
    transcriptViewRunning: "កំពុងធ្វើការនៅក្នុងទែមីណាល់ · Esc ដើម្បីរំខាន",
    transcriptViewIdle: "ផ្ញើទៅភ្នាក់ងារនៅក្នុងទែមីណាល់នេះ",
    answerInTerminal: "ឆ្លើយនៅក្នុងទែមីណាល់",
    agentMessageFrom: "សារពី {sender}",
    agentMessageQueued: "កំពុងរង់ចាំភ្នាក់ងារទទួលយក",
    loadingDiff: "កំពុងផ្ទុកភាពខុសគ្នា…",
    diffUnavailable: "មិនអាចផ្ទុកភាពខុសគ្នាបានទេ។ សូមព្យាយាមម្តងទៀត។",
    retryDiff: "ព្យាយាមម្តងទៀត",
  },
  uk: {
    continuedNewChat: "Продовжено в новому чаті. Попередній контекст пов’язано.",
    movedServingRoute: "Перемкнено на інший маршрут обслуговування. Контекст розмови збережено.",
    continueNewChat: "Продовжити в новому чаті",
    continueElsewhere: "Продовжити в іншому місці",
    transcriptViewRunning: "Працює в терміналі · Esc, щоб перервати",
    transcriptViewIdle: "Надсилається агентові в цьому терміналі",
    answerInTerminal: "Відповісти в терміналі",
    agentMessageFrom: "Повідомлення від {sender}",
    agentMessageQueued: "Чекає, доки агент його забере",
    loadingDiff: "Завантаження змін…",
    diffUnavailable: "Не вдалося завантажити зміни. Спробуйте ще раз.",
    retryDiff: "Повторити",
  },
};

const BY_LOWERCASE = new Map(
  AGENT_CHAT_LOCALES.map((locale) => [locale.toLowerCase(), locale] as const),
);

export function resolveAgentChatLocale(languages: readonly string[]): AgentChatLocale {
  for (const raw of languages) {
    const candidate = raw.trim();
    if (!candidate) continue;
    const exact = BY_LOWERCASE.get(candidate.toLowerCase());
    if (exact) return exact;

    const lower = candidate.toLowerCase();
    if (lower.startsWith("zh-")) {
      return /(?:^|-)hant(?:-|$)|-(?:tw|hk|mo)(?:-|$)/.test(lower) ? "zh-TW" : "zh-CN";
    }
    if (lower === "zh") return "zh-CN";
    if (lower === "pt" || lower.startsWith("pt-")) return "pt-BR";
    if (lower === "nb" || lower.startsWith("nb-") || lower === "nn" || lower.startsWith("nn-")) return "no";

    const language = lower.split("-", 1)[0];
    const languageMatch = AGENT_CHAT_LOCALES.find((locale) => locale.toLowerCase().split("-", 1)[0] === language);
    if (languageMatch) return languageMatch;
  }
  return "en";
}

function browserLanguages(): readonly string[] {
  if (typeof navigator === "undefined") return ["en"];
  return navigator.languages.length ? navigator.languages : [navigator.language];
}

export function agentChatText(key: AgentChatTextKey, languages = browserLanguages()): string {
  return COPY[resolveAgentChatLocale(languages)][key];
}

export function agentChatCopyForLocale(locale: AgentChatLocale): Readonly<Record<AgentChatTextKey, string>> {
  return COPY[locale];
}
