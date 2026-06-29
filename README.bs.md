> Ovaj prijevod je generisan od strane Claude. Ako imate prijedloge za poboljšanje, otvorite PR.

<h1 align="center">cmux</h1>
<p align="center">macOS terminal baziran na Ghostty sa vertikalnim tabovima i obavještenjima za AI agente za programiranje</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | Bosanski | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux snimak ekrana" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demo video</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
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
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> kreira radni prostor za udaljenu mašinu. Paneli preglednika se usmjeravaju kroz udaljenu mrežu tako da localhost jednostavno radi. Prevucite sliku u udaljenu sesiju za upload putem scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> pokreće teammate režim Claude Code sa jednom komandom. Članovi tima se pojavljuju kao nativni podijeljeni paneli sa metapodacima u bočnoj traci i obavještenjima. Nije potreban tmux.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Uvoz preglednika** — Uvezite kolačiće, historiju i sesije iz Chrome, Firefox, Arc i 20+ preglednika tako da paneli preglednika počnu autentificirani
- **Prilagođene komande** — Definirajte akcije specifične za projekt u [`cmux.json`](https://cmux.com/docs/custom-commands) koje se pokreću iz palete komandi
- **Skriptabilan** — CLI i socket API za kreiranje radnih prostora, dijeljenje panela, slanje pritisaka tipki i automatizaciju preglednika
- **Nativna macOS aplikacija** — Izgrađena sa Swift i AppKit, ne Electron. Brzo pokretanje, niska potrošnja memorije.
- **Kompatibilan sa Ghostty** — Čita vašu postojeću konfiguraciju `~/.config/ghostty/config` za teme, fontove i boje
- **GPU-ubrzanje** — Pokreće ga libghostty za glatko renderiranje
- **Prečice na tastaturi** — [Brojne prečice](https://cmux.com/docs/keyboard-shortcuts) za radne prostore, podjele, preglednik i više
- **Otvoreni kod** — Besplatan i pod GPL licencom

## Instalacija

### DMG (preporučeno)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
</a>

Otvorite `.dmg` datoteku i prevucite cmux u folder Aplikacije. cmux se automatski ažurira putem Sparkle, tako da trebate preuzeti samo jednom.

### Homebrew

```bash
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

Za više informacija o konfiguraciji cmux, posjetite [našu dokumentaciju](https://cmux.com/docs/getting-started?utm_source=readme).

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
| ⌥ ⌘ E | Uredi opis radnog prostora |
| ⌘ B | Prikaži/sakrij bočnu traku |
| ⌥ ⌘ B | Prikaži/sakrij desnu bočnu traku |
| ⌘ ⇧ E | Prebaci fokus desne bočne trake |

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

Prečice razvojnih alata preglednika prate Safari zadane postavke i mogu se prilagoditi u `Settings → Keyboard Shortcuts`.
Prečice za navigaciju paletom komandi, uključujući ⌃ P, također se mogu prilagoditi i obrisati tako da pritisak tipke dođe do aktivnog terminala.

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
| ⌥ ⌘ U | Prebaci stanje nepročitanog za trenutnu stavku |
| ⌃ ⌘ U | Označi trenutnu stavku kao najstarije nepročitano i skoči na sljedeće nepročitano |

### Pretraga

| Prečica | Akcija |
|----------|--------|
| ⌘ F | Pretraži |
| ⌘ ⇧ F | Pretraži u direktoriju |
| ⌘ G / ⌥ ⌘ G | Nađi sljedeći / prethodni |
| ⌥ ⌘ ⇧ F | Sakrij traku pretrage |
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
| ⌘ ⇧ O | Ponovo otvori prethodnu sesiju |
| ⌘ , | Postavke |
| ⌘ ⇧ , | Ponovo učitaj konfiguraciju |
| ⌘ Q | Zatvori |

## Noćne verzije

[Preuzmi cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY je zasebna aplikacija sa vlastitim bundle ID-om, tako da radi uporedo sa stabilnom verzijom. Automatski se gradi iz najnovijeg `main` commita i ažurira se putem vlastitog Sparkle feeda.

Prijavite greške noćnih verzija na [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) ili na [#nightly-bugs na Discordu](https://discord.gg/xsgFEVrWCZ).

## Vraćanje sesije

Kada zatvorite cmux, trenutna sesija se sprema. Pri ponovnom pokretanju cmux vraća stanje kojim upravlja aplikacija:
- Raspored prozora/radnih prostora/panela
- Radne direktorije
- Scrollback terminala (po mogućnosti)
- URL preglednika i historija navigacije

cmux ne pravi checkpoint proizvoljnog stanja živih procesa. tmux, vim, shellovi i nepodržane terminalne aplikacije ponovo se otvaraju kao obični terminali.

Podržane agent sesije mogu se nastaviti kada hooks spreme izvorni ID sesije. Instalirajte hooks nakon instalacije agent CLI-ja tako da njegov binarni fajl bude na `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` instalira podržane agente koje može pronaći i ispisuje sažetak za preskočene agente. Podržane integracije nastavka uključuju Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory i Qoder. Claude Code obrađuje cmux Claude wrapper kada je Claude integracija omogućena u Postavkama.

Napredni korisnici i integracije mogu vezati prilagođenu komandu za nastavak na trenutni terminal surface. To je korisno za alate s vlastitim trajnim stanjem, poput tmux sesija ili prilagođenih agent CLI alata:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Binding ostaje vezan za cmux surface. Bindingi napravljeni javnim CLI-jem ili socketom čuvaju se za pregled i ručni nastavak osim ako ne odobrite potpisani prefiks komande za automatski nastavak. Odobreni prefiksi su također vezani za radni direktorij i tačne vrijednosti okruženja, kada su prisutne. Pregledajte ili uredite odobrenja u **Settings > Terminal > Resume Commands**. cmux automatski pokreće samo resume bindinge koje označi pouzdanim, poput tmux bindinga otkrivenih iz živih procesa ili prefiksa koje je korisnik odobrio. Osjetljivi ključevi okruženja, poput tokena, lozinki, tajni i API ključeva, odbacuju se prije spremanja resume bindinga.

Da bi vraćeni agent terminali ostali neaktivni umjesto automatskog pokretanja svojih resume komandi, isključite **Settings > Terminal > Resume Agent Sessions on Reopen** ili postavite ovo u `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Ovo samo onemogućava automatske agent resume komande. cmux i dalje vraća sačuvani raspored, radne direktorije, scrollback i historiju preglednika.

Ako trebate ručno ponovo primijeniti posljednji sačuvani snimak, koristite:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

Ispod haube, cmux zapisuje verzionirani snimak u `~/Library/Application Support/cmux/`, a agent hooks zapisuju mapiranja sesija u `~/.cmuxterm/`. Pri vraćanju, cmux prvo obnavlja raspored, a zatim pokreće izvornu resume komandu podržanog agenta kada je automatski nastavak agenta omogućen.

Pročitajte cijeli vodič na <https://cmux.com/docs/session-restore>.

## FAQ

### Kako se cmux odnosi prema Ghostty?

cmux nije fork Ghostty. Koristi [libghostty](https://github.com/ghostty-org/ghostty) kao biblioteku za renderiranje terminala, na isti način kao što aplikacije koriste WebKit za web prikaze. Ghostty je samostalni terminal; cmux je drugačija aplikacija izgrađena na vrhu njegovog renderiranja.

### Koje platforme podržava?

Zasad samo macOS. cmux je nativna Swift + AppKit aplikacija.

### Postoji li iOS aplikacija?

Da, u beti. Uparite svoj iPhone sa svojim Mac-om iz prozora Mobile Connect i povežite se na svoje terminale sa telefona, uz opcionalno prosljeđivanje terminalnih obavještenja. Isporučuje se na TestFlight kao cmux BETA. Pogledajte [iOS dokumentaciju](https://cmux.com/docs/ios).

### Sa kojim agentima za programiranje cmux radi?

Sa svima. cmux je terminal, tako da svaki agent koji radi u terminalu radi odmah: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent i sve drugo što možete pokrenuti iz komandne linije.

### Može li cmux orkestrirati više agenata i podagenata?

Da. Kada agent stvori podagente ili članove tima, cmux ih pretvara u nativne panele i podjele umjesto skrivenih pozadinskih procesa. Podržava [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) i [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) orkestraciju više modela, tako da je svaki agent u pokretanju vidljiv i kontrolisan.

### Mogu li koristiti cmux sa udaljenim mašinama?

Da. Otvarajte radne prostore preko SSH-a i povezujte se na udaljene tmux sesije, tako da agenti mogu raditi na udaljenom hostu dok ih vi upravljate iz cmux-a. Pogledajte [SSH i udaljeno](https://cmux.com/docs/ssh).

### Kako rade obavještenja?

Kada proces treba pažnju, cmux prikazuje prstenove obavještenja oko panela, značke nepročitanog u bočnoj traci, popover obavještenja i macOS desktop obavještenje. Ona se pokreću automatski putem standardnih terminalnih escape sekvenci (OSC 9/99/777), ili ih možete pokrenuti pomoću [cmux CLI](https://cmux.com/docs/notifications#cli-usage) i [agent hookova](https://cmux.com/docs/notifications#integration-examples). Radi svaki agent koji podržava hooks ili OSC, uključujući Claude Code, Codex, OpenCode i pi.

### Je li cmux programabilan?

Da. Svaka akcija je dostupna putem cmux CLI-ja i Unix socketa: kreirajte radne prostore, otvarajte podijeljene panele, šaljite unos, čitajte sadržaj ekrana, pravite snimke ekrana i upravljajte ugrađenim preglednikom. Pogledajte [CLI referencu](https://cmux.com/docs/api) i dokumentaciju [automatizacije preglednika](https://cmux.com/docs/browser-automation).

### Šta ugrađeni preglednik može?

cmux može podijeliti pravi panel preglednika pored vašeg terminala, i potpuno je programabilan: navigirajte, snimite DOM, kliknite, kucajte, evaluirajte JavaScript i čitajte aktivnost konzole i mreže preko istog socket API-ja. Agenti ga koriste za provjeru vlastitih web promjena bez napuštanja cmux-a. Pogledajte [automatizaciju preglednika](https://cmux.com/docs/browser-automation).

### Ima li cmux vještine (skills)?

Da. Vještine su ponovo upotrebljivi tokovi rada koje možete dati bilo kojem agentu koji radi u cmux-u, za stvari poput kontrole CLI-ja, automatizacije radnog prostora, postavki i preglednik površina. Pregledajte otvorenu kolekciju na [cmux-skills](https://github.com/manaflow-ai/cmux-skills), ili pročitajte [dokumentaciju o vještinama](https://cmux.com/docs/skills).

### Mogu li prilagoditi prečice na tastaturi?

Terminalne tastaturne prečice se čitaju iz vašeg Ghostty konfiguracijskog fajla (`~/.config/ghostty/config`). Prečice specifične za cmux (radni prostori, podjele, preglednik, obavještenja) mogu se prilagoditi u Postavkama. Pogledajte [zadane prečice](https://cmux.com/docs/keyboard-shortcuts) za potpunu listu.

### Mogu li prilagoditi cmux?

Da. Renderiranje terminala koristi vašu Ghostty konfiguraciju, tako da se teme, fontovi, boje i kursor prenose direktno. Vlastite postavke cmux-a u `~/.config/cmux/cmux.json` kontrolišu bočnu traku, traku tabova, podijeljene panele i ponašanje, a svaka [tastaturna prečica](https://cmux.com/docs/keyboard-shortcuts) je uređiva. Pogledajte [konfiguraciju](https://cmux.com/docs/configuration).

### Jesu li moje sesije sačuvane?

Da. cmux vraća vaše prozore, radne prostore, panele, radne direktorije i scrollback kada ponovo pokrenete, a stanje preživljava potpuni restart računara, ne samo zatvaranje aplikacije. Agent sesije poput Claude Code, Codex i OpenCode se također vraćaju. Pogledajte [vraćanje sesije](https://cmux.com/docs/session-restore).

### Kako se poredi sa tmux?

tmux je terminalni multiplekser koji radi unutar bilo kojeg terminala. cmux je nativna macOS aplikacija sa GUI-jem: vertikalni tabovi, podijeljeni paneli, ugrađeni preglednik i socket API, sve ugrađeno, bez konfiguracijskih fajlova ili prefiks tipki. Uz to, mnogo ljudi rado pokreće cmux sa SSH-om i tmux-om zajedno, a cmux se može nativno povezati na vaše udaljene tmux sesije ([beta](https://cmux.com/docs/remote-tmux)).

### Je li cmux besplatan?

Da, cmux je besplatan za korištenje. Izvorni kod je dostupan na [GitHub-u](https://github.com/manaflow-ai/cmux).

### Kako mogu podržati cmux?

cmux je besplatan i otvorenog koda, i uvijek će biti. Ako želite podržati razvoj i dobiti rani pristup onome što slijedi, uključujući cmux AI, iOS aplikaciju i Cloud VMs, pogledajte [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Imam zahtjev za funkciju ili sam pronašao grešku?

Želimo to čuti. Otvorite [issue](https://github.com/manaflow-ai/cmux/issues) ili [pull request](https://github.com/manaflow-ai/cmux/pulls) na GitHub-u, ili nam [pošaljite email](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

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

cmux je otvorenog koda pod [GPL-3.0-or-later](LICENSE) licencom.

Ako vaša organizacija ne može ispuniti uslove GPL-a, dostupna je komercijalna licenca. Kontaktirajte [founders@manaflow.com](mailto:founders@manaflow.com) za detalje.
