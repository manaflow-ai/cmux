> Ovaj prijevod je generisan od strane Claude. Ako imate prijedloge za poboljšanje, otvorite PR.

<h1 align="center">cmux</h1>
<p align="center">macOS terminal baziran na Ghostty sa vertikalnim tabovima i obavještenjima za AI agente za programiranje</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | Bosanski | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux snimak ekrana" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demo video</a> · <a href="https://cmux.dev/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funkcije

<table>
<tr>
<td width="40%" valign="middle">
<h3>Prstenovi obavještenja</h3>
Paneli dobijaju plavi prsten, a tabovi se osvjetljavaju kada agenti za programiranje trebaju vašu pažnju
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Prstenovi obavještenja" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Panel obavještenja</h3>
Pregledajte sva obavještenja na čekanju na jednom mjestu, skočite na najnovije nepročitano
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Značka obavještenja u bočnoj traci" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Ugrađeni preglednik</h3>
Podijelite preglednik pored terminala sa skriptabilnim API portiranim iz <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Ugrađeni preglednik" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertikalni + horizontalni tabovi</h3>
Bočna traka prikazuje git granu, status/broj povezanog PR-a, radni direktorij, portove koji slušaju i tekst posljednjeg obavještenja. Horizontalna i vertikalna podjela.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertikalni tabovi i podijeljeni paneli" width="100%" />
</td>
</tr>
</table>

- **Skriptabilan** — CLI i socket API za kreiranje radnih prostora, dijeljenje panela, slanje pritisaka tipki i automatizaciju preglednika
- **Nativna macOS aplikacija** — Izgrađena sa Swift i AppKit, ne Electron. Brzo pokretanje, niska potrošnja memorije.
- **Kompatibilan sa Ghostty** — Čita vašu postojeću konfiguraciju `~/.config/ghostty/config` za teme, fontove i boje
- **GPU-ubrzanje** — Pokreće ga libghostty za glatko renderiranje

## Instalacija

### DMG (preporučeno)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
</a>

Otvorite `.dmg` datoteku i prevucite cmux u folder Aplikacije. cmux se automatski ažurira putem Sparkle, tako da trebate preuzeti samo jednom.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Za ažuriranje kasnije:

```bash
brew upgrade --cask cmux
```

Pri prvom pokretanju, macOS vas može zamoliti da potvrdite otvaranje aplikacije od identificiranog programera. Kliknite **Otvori** da nastavite.

## Zašto cmux?

Pokrećem mnogo Claude Code i Codex sesija paralelno. Koristio sam Ghostty sa gomilom podijeljenih panela i oslanjao se na nativna macOS obavještenja da znam kada agent treba mene. Ali tijelo obavještenja Claude Code je uvijek samo „Claude is waiting for your input" bez konteksta, a sa dovoljno otvorenih tabova nisam mogao ni pročitati naslove.

Isprobao sam nekoliko orkestratora za kodiranje, ali većina ih je bila Electron/Tauri aplikacije i performanse su me nervirale. Također jednostavno preferiram terminal jer GUI orkestratori vas zaključavaju u svoj radni tok. Zato sam izgradio cmux kao nativnu macOS aplikaciju u Swift/AppKit. Koristi libghostty za renderiranje terminala i čita vašu postojeću Ghostty konfiguraciju za teme, fontove i boje.

Glavni dodaci su bočna traka i sistem obavještenja. Bočna traka ima vertikalne tabove koji prikazuju git granu, status/broj povezanog PR-a, radni direktorij, portove koji slušaju i tekst posljednjeg obavještenja za svaki radni prostor. Sistem obavještenja hvata terminalne sekvence (OSC 9/99/777) i ima CLI (`cmux notify`) koji možete povezati sa hookovima agenata za Claude Code, OpenCode itd. Kada agent čeka, njegov panel dobija plavi prsten, a tab se osvjetljava u bočnoj traci, tako da mogu vidjeti koji me treba kroz podjele i tabove. Cmd+Shift+U skače na najnovije nepročitano.

Ugrađeni preglednik ima skriptabilni API portiran iz [agent-browser](https://github.com/vercel-labs/agent-browser). Agenti mogu snimiti stablo pristupačnosti, dobiti reference elemenata, kliknuti, popuniti formulare i evaluirati JS. Možete podijeliti panel preglednika pored terminala i omogućiti Claude Code da direktno komunicira sa vašim razvojnim serverom.

Sve je skriptabilno kroz CLI i socket API — kreiranje radnih prostora/tabova, dijeljenje panela, slanje pritisaka tipki, otvaranje URL-ova u pregledniku.

## The Zen of cmux

cmux ne propisuje programerima kako da koriste svoje alate. To je terminal i preglednik sa CLI-jem, a ostatak je na vama.

cmux je primitiv, ne rješenje. Daje vam terminal, preglednik, obavještenja, radne prostore, podjele, tabove i CLI za kontrolu svega toga. cmux vas ne prisiljava na određeni način korištenja agenata za kodiranje. Ono što izgradite sa tim primitivima je vaše.

Najbolji programeri su oduvijek gradili vlastite alate. Niko još nije otkrio najbolji način rada sa agentima, a timovi koji grade zatvorene proizvode to također nisu uradili. Programeri koji su najbliži svojim bazama koda će to otkriti prvi.

Dajte milion programera kompozabilne primitive i oni će kolektivno pronaći najefikasnije tokove rada brže nego što bi bilo koji produktni tim mogao dizajnirati odozgo prema dolje.

## Dokumentacija

Za više informacija o konfiguraciji cmux, posjetite [našu dokumentaciju](https://cmux.dev/docs/getting-started?utm_source=readme).

## Prečice na Tastaturi

### Radni prostori

| Prečica | Akcija |
|----------|--------|
| ⌘ N | Novi radni prostor |
| ⌘ 1–8 | Skoči na radni prostor 1–8 |
| ⌘ 9 | Skoči na posljednji radni prostor |
| ⌃ ⌘ ] | Sljedeći radni prostor |
| ⌃ ⌘ [ | Prethodni radni prostor |
| ⌘ ⇧ W | Zatvori radni prostor |
| ⌘ ⇧ R | Preimenuj radni prostor |
| ⌘ B | Prikaži/sakrij bočnu traku |

### Površine

| Prečica | Akcija |
|----------|--------|
| ⌘ T | Nova površina |
| ⌘ ⇧ ] | Sljedeća površina |
| ⌘ ⇧ [ | Prethodna površina |
| ⌃ Tab | Sljedeća površina |
| ⌃ ⇧ Tab | Prethodna površina |
| ⌃ 1–8 | Skoči na površinu 1–8 |
| ⌃ 9 | Skoči na posljednju površinu |
| ⌘ W | Zatvori površinu |

### Podijeljeni Paneli

| Prečica | Akcija |
|----------|--------|
| ⌘ D | Podijeli desno |
| ⌘ ⇧ D | Podijeli dolje |
| ⌥ ⌘ ← → ↑ ↓ | Fokusiraj panel po smjeru |
| ⌘ ⇧ H | Trepni fokusiranim panelom |

### Preglednik

Prečice razvojnih alata preglednika prate Safari zadane postavke i mogu se prilagoditi u `Postavke → Prečice na tastaturi`.

| Prečica | Akcija |
|----------|--------|
| ⌘ ⇧ L | Otvori preglednik u podjeli |
| ⌘ L | Fokusiraj adresnu traku |
| ⌘ [ | Nazad |
| ⌘ ] | Naprijed |
| ⌘ R | Ponovo učitaj stranicu |
| ⌥ ⌘ I | Prikaži/sakrij Alate za Programere (Safari zadano) |
| ⌥ ⌘ C | Prikaži JavaScript Konzolu (Safari zadano) |

### Obavještenja

| Prečica | Akcija |
|----------|--------|
| ⌘ I | Prikaži panel obavještenja |
| ⌘ ⇧ U | Skoči na posljednje nepročitano |

### Pretraga

| Prečica | Akcija |
|----------|--------|
| ⌘ F | Pretraži |
| ⌘ G / ⌘ ⇧ G | Nađi sljedeći / prethodni |
| ⌘ ⇧ F | Sakrij traku pretrage |
| ⌘ E | Koristi selekciju za pretragu |

### Terminal

| Prečica | Akcija |
|----------|--------|
| ⌘ K | Očisti scrollback |
| ⌘ C | Kopiraj (sa selekcijom) |
| ⌘ V | Zalijepi |
| ⌘ + / ⌘ - | Povećaj / smanji veličinu fonta |
| ⌘ 0 | Resetuj veličinu fonta |

### Prozor

| Prečica | Akcija |
|----------|--------|
| ⌘ ⇧ N | Novi prozor |
| ⌘ , | Postavke |
| ⌘ ⇧ , | Ponovo učitaj konfiguraciju |
| ⌘ Q | Zatvori |

## Noćne verzije

[Preuzmi cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY je zasebna aplikacija sa vlastitim bundle ID-om, tako da radi uporedo sa stabilnom verzijom. Automatski se gradi iz najnovijeg `main` commita i ažurira se putem vlastitog Sparkle feeda.

## Vraćanje sesije (trenutno ponašanje)

Prilikom ponovnog pokretanja, cmux trenutno vraća samo raspored aplikacije i metapodatke:
- Raspored prozora/radnih prostora/panela
- Radne direktorije
- Scrollback terminala (po mogućnosti)
- URL preglednika i historija navigacije

cmux **ne** vraća stanje živih procesa unutar terminalnih aplikacija. Na primjer, aktivne sesije Claude Code/tmux/vim se još ne nastavljaju nakon restarta.

## Historija zvjezdica

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Doprinos

Načini da se uključite:

- Pratite nas na X za ažuriranja [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) i [@austinywang](https://x.com/austinywang)
- Pridružite se razgovoru na [Discordu](https://discord.gg/xsgFEVrWCZ)
- Kreirajte i učestvujte u [GitHub issues](https://github.com/manaflow-ai/cmux/issues) i [diskusijama](https://github.com/manaflow-ai/cmux/discussions)
- Javite nam šta gradite sa cmux

## Zajednica

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Osnivačko izdanje

cmux je besplatan, otvorenog koda i uvijek će biti. Ako želite podržati razvoj i dobiti rani pristup onome što dolazi:

**[Nabavite Osnivačko izdanje](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioritetni zahtjevi za funkcije/ispravke grešaka**
- **Rani pristup: cmux AI koji vam daje kontekst o svakom radnom prostoru, tabu i panelu**
- **Rani pristup: iOS aplikacija sa terminalima sinhroniziranim između desktopa i telefona**
- **Rani pristup: Cloud VM-ovi**
- **Rani pristup: Glasovni režim**
- **Moj lični iMessage/WhatsApp**

## Licenca

Ovaj projekat je licenciran pod GNU Affero General Public License v3.0 ili novijom (`AGPL-3.0-or-later`).

Pogledajte `LICENSE` za puni tekst.
