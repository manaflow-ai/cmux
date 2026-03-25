> تمت هذه الترجمة بواسطة Claude. إذا كانت لديك اقتراحات للتحسين، يرجى فتح PR.

<h1 align="center">cmux</h1>
<p align="center">تطبيق طرفية لنظام macOS مبني على Ghostty مع علامات تبويب عمودية وإشعارات لوكلاء البرمجة بالذكاء الاصطناعي</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="تحميل cmux لنظام macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | العربية | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="لقطة شاشة cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ فيديو توضيحي</a> · <a href="https://cmux.com/blog/zen-of-cmux">فلسفة cmux</a>
</p>

## الميزات

<table>
<tr>
<td width="40%" valign="middle">
<h3>حلقات الإشعارات</h3>
تحصل الأجزاء على حلقة زرقاء وتضيء علامات التبويب عندما يحتاج وكلاء البرمجة انتباهك
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="حلقات الإشعارات" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>لوحة الإشعارات</h3>
عرض جميع الإشعارات المعلقة في مكان واحد، والانتقال إلى أحدث إشعار غير مقروء
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="شارة إشعارات الشريط الجانبي" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>متصفح مدمج</h3>
قسّم متصفحًا بجانب الطرفية مع API قابل للبرمجة مأخوذ من <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="المتصفح المدمج" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>علامات تبويب عمودية + أفقية</h3>
يعرض الشريط الجانبي فرع git وحالة/رقم طلب السحب المرتبط ومجلد العمل والمنافذ المستمعة وآخر نص إشعار. تقسيم أفقي وعمودي.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="علامات تبويب عمودية وأجزاء مقسمة" width="100%" />
</td>
</tr>
</table>

- **قابل للبرمجة** — CLI وsocket API لإنشاء مساحات العمل وتقسيم الأجزاء وإرسال ضغطات المفاتيح وأتمتة المتصفح
- **تطبيق macOS أصلي** — مبني بـ Swift وAppKit، وليس Electron. بدء تشغيل سريع واستهلاك ذاكرة منخفض.
- **متوافق مع Ghostty** — يقرأ إعداداتك الحالية من `~/.config/ghostty/config` للسمات والخطوط والألوان
- **تسريع GPU** — مدعوم بـ libghostty لعرض سلس

## التثبيت

### DMG (مستحسن)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="تحميل cmux لنظام macOS" width="180" />
</a>

افتح ملف `.dmg` واسحب cmux إلى مجلد التطبيقات. يتم تحديث cmux تلقائيًا عبر Sparkle، لذا تحتاج للتحميل مرة واحدة فقط.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

للتحديث لاحقًا:

```bash
brew upgrade --cask cmux
```

عند التشغيل الأول، قد يطلب منك macOS تأكيد فتح تطبيق من مطور معروف. انقر **فتح** للمتابعة.

## لماذا cmux؟

أقوم بتشغيل الكثير من جلسات Claude Code وCodex بالتوازي. كنت أستخدم Ghostty مع مجموعة من الأجزاء المقسمة، وأعتمد على إشعارات macOS الأصلية لمعرفة متى يحتاجني وكيل ما. لكن نص إشعار Claude Code يكون دائمًا مجرد "Claude is waiting for your input" بدون أي سياق، ومع فتح عدد كافٍ من علامات التبويب لم أعد قادرًا حتى على قراءة العناوين.

جربت بعض منظمات البرمجة لكن معظمها كانت تطبيقات Electron/Tauri وأداؤها كان يزعجني. كما أنني أفضل الطرفية لأن منظمات GUI تحبسك في سير عملها. لذا بنيت cmux كتطبيق macOS أصلي بـ Swift/AppKit. يستخدم libghostty لعرض الطرفية ويقرأ إعدادات Ghostty الحالية للسمات والخطوط والألوان.

الإضافات الرئيسية هي الشريط الجانبي ونظام الإشعارات. يحتوي الشريط الجانبي على علامات تبويب عمودية تعرض فرع git وحالة/رقم طلب السحب المرتبط ومجلد العمل والمنافذ المستمعة وآخر نص إشعار لكل مساحة عمل. يلتقط نظام الإشعارات تسلسلات الطرفية (OSC 9/99/777) ولديه CLI (`cmux notify`) يمكنك ربطه بخطافات الوكلاء لـ Claude Code وOpenCode وغيرها. عندما ينتظر وكيل ما، يحصل جزؤه على حلقة زرقاء وتضيء علامة التبويب في الشريط الجانبي، حتى أتمكن من معرفة أيها يحتاجني عبر الأقسام وعلامات التبويب. Cmd+Shift+U ينتقل إلى أحدث إشعار غير مقروء.

المتصفح المدمج لديه API قابل للبرمجة مأخوذ من [agent-browser](https://github.com/vercel-labs/agent-browser). يمكن للوكلاء التقاط شجرة إمكانية الوصول والحصول على مراجع العناصر والنقر وملء النماذج وتنفيذ JS. يمكنك تقسيم جزء متصفح بجانب الطرفية وجعل Claude Code يتفاعل مع خادم التطوير مباشرة.

كل شيء قابل للبرمجة عبر CLI وsocket API — إنشاء مساحات العمل/علامات التبويب، تقسيم الأجزاء، إرسال ضغطات المفاتيح، فتح عناوين URL في المتصفح.

## فلسفة cmux

cmux لا يفرض على المطورين طريقة استخدام أدواتهم. إنه طرفية ومتصفح مع واجهة سطر أوامر، والباقي متروك لك.

cmux هو لبنة أساسية وليس حلًا جاهزًا. يمنحك طرفية ومتصفحًا وإشعارات ومساحات عمل وأقسامًا وعلامات تبويب وواجهة سطر أوامر للتحكم في كل ذلك. cmux لا يجبرك على طريقة محددة لاستخدام وكلاء البرمجة. ما تبنيه باستخدام هذه اللبنات الأساسية هو ملكك.

أفضل المطورين دائمًا ما بنوا أدواتهم الخاصة. لم يكتشف أحد بعد أفضل طريقة للعمل مع الوكلاء، والفرق التي تبني منتجات مغلقة لم تكتشفها أيضًا بالتأكيد. المطورون الأقرب لقواعد بياناتهم الخاصة سيكتشفونها أولًا.

أعطِ مليون مطور لبنات أساسية قابلة للتركيب وسيجدون بشكل جماعي أكثر سير العمل كفاءة أسرع مما يمكن لأي فريق منتج تصميمه من الأعلى إلى الأسفل.

## التوثيق

لمزيد من المعلومات حول كيفية إعداد cmux، [توجه إلى وثائقنا](https://cmux.com/docs/getting-started?utm_source=readme).

## اختصارات لوحة المفاتيح

### مساحات العمل

| الاختصار | الإجراء |
|----------|--------|
| ⌘ N | مساحة عمل جديدة |
| ⌘ 1–8 | الانتقال إلى مساحة العمل 1–8 |
| ⌘ 9 | الانتقال إلى آخر مساحة عمل |
| ⌃ ⌘ ] | مساحة العمل التالية |
| ⌃ ⌘ [ | مساحة العمل السابقة |
| ⌘ ⇧ W | إغلاق مساحة العمل |
| ⌘ ⇧ R | إعادة تسمية مساحة العمل |
| ⌘ B | تبديل الشريط الجانبي |

### الأسطح

| الاختصار | الإجراء |
|----------|--------|
| ⌘ T | سطح جديد |
| ⌘ ⇧ ] | السطح التالي |
| ⌘ ⇧ [ | السطح السابق |
| ⌃ Tab | السطح التالي |
| ⌃ ⇧ Tab | السطح السابق |
| ⌃ 1–8 | الانتقال إلى السطح 1–8 |
| ⌃ 9 | الانتقال إلى آخر سطح |
| ⌘ W | إغلاق السطح |

### الأجزاء المقسمة

| الاختصار | الإجراء |
|----------|--------|
| ⌘ D | تقسيم لليمين |
| ⌘ ⇧ D | تقسيم للأسفل |
| ⌥ ⌘ ← → ↑ ↓ | التركيز على الجزء حسب الاتجاه |
| ⌘ ⇧ H | وميض الجزء المركّز عليه |

### المتصفح

اختصارات أدوات المطور في المتصفح تتبع إعدادات Safari الافتراضية ويمكن تخصيصها في `الإعدادات ← اختصارات لوحة المفاتيح`.

| الاختصار | الإجراء |
|----------|--------|
| ⌘ ⇧ L | فتح المتصفح في قسم |
| ⌘ L | التركيز على شريط العنوان |
| ⌘ [ | للخلف |
| ⌘ ] | للأمام |
| ⌘ R | إعادة تحميل الصفحة |
| ⌥ ⌘ I | تبديل أدوات المطور (إعداد Safari الافتراضي) |
| ⌥ ⌘ C | عرض وحدة تحكم JavaScript (إعداد Safari الافتراضي) |

### الإشعارات

| الاختصار | الإجراء |
|----------|--------|
| ⌘ I | عرض لوحة الإشعارات |
| ⌘ ⇧ U | الانتقال إلى أحدث إشعار غير مقروء |

### البحث

| الاختصار | الإجراء |
|----------|--------|
| ⌘ F | بحث |
| ⌘ G / ⌘ ⇧ G | البحث التالي / السابق |
| ⌘ ⇧ F | إخفاء شريط البحث |
| ⌘ E | استخدام التحديد للبحث |

### الطرفية

| الاختصار | الإجراء |
|----------|--------|
| ⌘ K | مسح سجل التمرير |
| ⌘ C | نسخ (مع التحديد) |
| ⌘ V | لصق |
| ⌘ + / ⌘ - | تكبير / تصغير حجم الخط |
| ⌘ 0 | إعادة تعيين حجم الخط |

### النافذة

| الاختصار | الإجراء |
|----------|--------|
| ⌘ ⇧ N | نافذة جديدة |
| ⌘ , | الإعدادات |
| ⌘ ⇧ , | إعادة تحميل الإعدادات |
| ⌘ Q | إنهاء |

## الإصدارات الليلية

[تحميل cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY هو تطبيق منفصل بمعرّف حزمة خاص به، لذا يعمل بجانب الإصدار المستقر. يُبنى تلقائيًا من أحدث commit على فرع `main` ويتم تحديثه تلقائيًا عبر Sparkle الخاص به.

## استعادة الجلسة (السلوك الحالي)

عند إعادة التشغيل، يستعيد cmux حاليًا تخطيط التطبيق والبيانات الوصفية فقط:
- تخطيط النوافذ/مساحات العمل/الأجزاء
- مجلدات العمل
- سجل تمرير الطرفية (أفضل جهد)
- عنوان URL للمتصفح وسجل التنقل

cmux **لا** يستعيد حالة العمليات الحية داخل تطبيقات الطرفية. على سبيل المثال، جلسات Claude Code/tmux/vim النشطة لا يتم استئنافها بعد إعادة التشغيل بعد.

## تاريخ النجوم

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## المساهمة

طرق للمشاركة:

- تابعنا على X للتحديثات [@manaflowai](https://x.com/manaflowai)، [@lawrencecchen](https://x.com/lawrencecchen)، و[@austinywang](https://x.com/austinywang)
- انضم إلى المحادثة على [Discord](https://discord.gg/xsgFEVrWCZ)
- أنشئ وشارك في [قضايا GitHub](https://github.com/manaflow-ai/cmux/issues) و[المناقشات](https://github.com/manaflow-ai/cmux/discussions)
- أخبرنا بما تبنيه باستخدام cmux

## المجتمع

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## إصدار المؤسسين

cmux مجاني ومفتوح المصدر وسيظل كذلك دائمًا. إذا كنت ترغب في دعم التطوير والحصول على وصول مبكر لما هو قادم:

**[احصل على إصدار المؤسسين](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **أولوية لطلبات الميزات/إصلاح الأخطاء**
- **وصول مبكر: ذكاء اصطناعي لـ cmux يمنحك سياقًا عن كل مساحة عمل وعلامة تبويب ولوحة**
- **وصول مبكر: تطبيق iOS مع مزامنة الطرفيات بين سطح المكتب والهاتف**
- **وصول مبكر: أجهزة افتراضية سحابية**
- **وصول مبكر: وضع الصوت**
- **iMessage/WhatsApp الشخصي الخاص بي**

## الرخصة

cmux مفتوح المصدر بموجب [AGPL-3.0-or-later](LICENSE).

إذا لم تستطع مؤسستك الامتثال لـ AGPL، فهناك ترخيص تجاري متاح. تواصل مع [founders@manaflow.com](mailto:founders@manaflow.com) للتفاصيل.
