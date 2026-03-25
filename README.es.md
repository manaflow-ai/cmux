> Esta traducción fue generada por Claude. Si tienes sugerencias de mejora, abre un PR.

<h1 align="center">cmux</h1>
<p align="center">Un terminal macOS basado en Ghostty con pestañas verticales y notificaciones para agentes de programación con IA</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Descargar cmux para macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | Español | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Captura de pantalla de cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Video de demostración</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Características

<table>
<tr>
<td width="40%" valign="middle">
<h3>Anillos de notificación</h3>
Los paneles obtienen un anillo azul y las pestañas se iluminan cuando los agentes de programación necesitan tu atención
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Anillos de notificación" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Panel de notificaciones</h3>
Ve todas las notificaciones pendientes en un solo lugar, salta a la más reciente no leída
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Insignia de notificación en la barra lateral" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Navegador integrado</h3>
Divide un navegador junto a tu terminal con una API programable portada de <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Navegador integrado" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Pestañas verticales + horizontales</h3>
La barra lateral muestra la rama de git, el estado/número del PR vinculado, el directorio de trabajo, los puertos en escucha y el texto de la última notificación. Divide horizontal y verticalmente.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Pestañas verticales y paneles divididos" width="100%" />
</td>
</tr>
</table>

- **Programable** — CLI y API de socket para crear espacios de trabajo, dividir paneles, enviar pulsaciones de teclas y automatizar el navegador
- **App nativa de macOS** — Construida con Swift y AppKit, no con Electron. Inicio rápido, bajo consumo de memoria.
- **Compatible con Ghostty** — Lee tu configuración existente en `~/.config/ghostty/config` para temas, fuentes y colores
- **Aceleración por GPU** — Impulsado por libghostty para un renderizado fluido

## Instalación

### DMG (recomendado)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Descargar cmux para macOS" width="180" />
</a>

Abre el `.dmg` y arrastra cmux a tu carpeta de Aplicaciones. cmux se actualiza automáticamente a través de Sparkle, así que solo necesitas descargarlo una vez.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Para actualizar más tarde:

```bash
brew upgrade --cask cmux
```

En el primer inicio, macOS puede pedirte que confirmes la apertura de una app de un desarrollador identificado. Haz clic en **Abrir** para continuar.

## ¿Por qué cmux?

Ejecuto muchas sesiones de Claude Code y Codex en paralelo. Estaba usando Ghostty con un montón de paneles divididos y dependía de las notificaciones nativas de macOS para saber cuándo un agente me necesitaba. Pero el cuerpo de la notificación de Claude Code siempre es solo "Claude is waiting for your input" sin contexto, y con suficientes pestañas abiertas ya ni siquiera podía leer los títulos.

Probé algunos orquestadores de programación, pero la mayoría eran aplicaciones Electron/Tauri y el rendimiento me molestaba. Además, simplemente prefiero la terminal ya que los orquestadores con GUI te encierran en su flujo de trabajo. Así que construí cmux como una app nativa de macOS en Swift/AppKit. Usa libghostty para el renderizado del terminal y lee tu configuración existente de Ghostty para temas, fuentes y colores.

Las principales adiciones son la barra lateral y el sistema de notificaciones. La barra lateral tiene pestañas verticales que muestran la rama de git, el estado/número del PR vinculado, el directorio de trabajo, los puertos en escucha y el texto de la última notificación para cada espacio de trabajo. El sistema de notificaciones detecta secuencias de terminal (OSC 9/99/777) y tiene un CLI (`cmux notify`) que puedes conectar a los hooks de agentes para Claude Code, OpenCode, etc. Cuando un agente está esperando, su panel obtiene un anillo azul y la pestaña se ilumina en la barra lateral, para que pueda saber cuál me necesita entre divisiones y pestañas. ⌘⇧U salta a la notificación no leída más reciente.

El navegador integrado tiene una API programable portada de [agent-browser](https://github.com/vercel-labs/agent-browser). Los agentes pueden capturar el árbol de accesibilidad, obtener referencias de elementos, hacer clic, rellenar formularios y ejecutar JS. Puedes dividir un panel de navegador junto a tu terminal y hacer que Claude Code interactúe directamente con tu servidor de desarrollo.

Todo es programable a través del CLI y la API de socket — crear espacios de trabajo/pestañas, dividir paneles, enviar pulsaciones de teclas, abrir URLs en el navegador.

## The Zen of cmux

cmux no prescribe cómo los desarrolladores deben usar sus herramientas. Es un terminal y navegador con un CLI, y el resto depende de ti.

cmux es un primitivo, no una solución. Te da un terminal, un navegador, notificaciones, espacios de trabajo, divisiones, pestañas y un CLI para controlarlo todo. cmux no te obliga a usar los agentes de programación de una manera específica. Lo que construyas con los primitivos es tuyo.

Los mejores desarrolladores siempre han construido sus propias herramientas. Nadie ha descubierto la mejor manera de trabajar con agentes todavía, y los equipos que construyen productos cerrados tampoco. Los desarrolladores más cercanos a sus propias bases de código lo descubrirán primero.

Dale a un millón de desarrolladores primitivos componibles y encontrarán colectivamente los flujos de trabajo más eficientes más rápido de lo que cualquier equipo de producto podría diseñar de arriba hacia abajo.

## Documentación

Para más información sobre cómo configurar cmux, [visita nuestra documentación](https://cmux.com/docs/getting-started?utm_source=readme).

## Atajos de teclado

### Espacios de trabajo

| Atajo | Acción |
|----------|--------|
| ⌘ N | Nuevo espacio de trabajo |
| ⌘ 1–8 | Ir al espacio de trabajo 1–8 |
| ⌘ 9 | Ir al último espacio de trabajo |
| ⌃ ⌘ ] | Siguiente espacio de trabajo |
| ⌃ ⌘ [ | Espacio de trabajo anterior |
| ⌘ ⇧ W | Cerrar espacio de trabajo |
| ⌘ ⇧ R | Renombrar espacio de trabajo |
| ⌘ B | Alternar barra lateral |

### Superficies

| Atajo | Acción |
|----------|--------|
| ⌘ T | Nueva superficie |
| ⌘ ⇧ ] | Siguiente superficie |
| ⌘ ⇧ [ | Superficie anterior |
| ⌃ Tab | Siguiente superficie |
| ⌃ ⇧ Tab | Superficie anterior |
| ⌃ 1–8 | Ir a la superficie 1–8 |
| ⌃ 9 | Ir a la última superficie |
| ⌘ W | Cerrar superficie |

### Paneles divididos

| Atajo | Acción |
|----------|--------|
| ⌘ D | Dividir a la derecha |
| ⌘ ⇧ D | Dividir hacia abajo |
| ⌥ ⌘ ← → ↑ ↓ | Enfocar panel direccionalmente |
| ⌘ ⇧ H | Destellar panel enfocado |

### Navegador

Los atajos de herramientas de desarrollo del navegador siguen los valores predeterminados de Safari y son personalizables en `Ajustes → Atajos de teclado`.

| Atajo | Acción |
|----------|--------|
| ⌘ ⇧ L | Abrir navegador en división |
| ⌘ L | Enfocar barra de direcciones |
| ⌘ [ | Atrás |
| ⌘ ] | Adelante |
| ⌘ R | Recargar página |
| ⌥ ⌘ I | Alternar herramientas de desarrollo (predeterminado de Safari) |
| ⌥ ⌘ C | Mostrar consola de JavaScript (predeterminado de Safari) |

### Notificaciones

| Atajo | Acción |
|----------|--------|
| ⌘ I | Mostrar panel de notificaciones |
| ⌘ ⇧ U | Ir a la última no leída |

### Buscar

| Atajo | Acción |
|----------|--------|
| ⌘ F | Buscar |
| ⌘ G / ⌘ ⇧ G | Buscar siguiente / anterior |
| ⌘ ⇧ F | Ocultar barra de búsqueda |
| ⌘ E | Usar selección para buscar |

### Terminal

| Atajo | Acción |
|----------|--------|
| ⌘ K | Limpiar historial de desplazamiento |
| ⌘ C | Copiar (con selección) |
| ⌘ V | Pegar |
| ⌘ + / ⌘ - | Aumentar / disminuir tamaño de fuente |
| ⌘ 0 | Restablecer tamaño de fuente |

### Ventana

| Atajo | Acción |
|----------|--------|
| ⌘ ⇧ N | Nueva ventana |
| ⌘ , | Ajustes |
| ⌘ ⇧ , | Recargar configuración |
| ⌘ Q | Salir |

## Compilaciones nocturnas

[Descargar cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY es una app separada con su propio bundle ID, por lo que se ejecuta junto a la versión estable. Se compila automáticamente desde el último commit de `main` y se actualiza automáticamente a través de su propio feed de Sparkle.

## Restauración de sesión (comportamiento actual)

Al relanzar, cmux actualmente restaura solo el diseño y los metadatos de la aplicación:
- Diseño de ventanas/espacios de trabajo/paneles
- Directorios de trabajo
- Historial de desplazamiento del terminal (mejor esfuerzo)
- URL del navegador e historial de navegación

cmux **no** restaura el estado de los procesos activos dentro de las aplicaciones de terminal. Por ejemplo, las sesiones activas de Claude Code/tmux/vim no se reanudan después de reiniciar todavía.

## Historial de estrellas

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Contribuir

Formas de participar:

- Síguenos en X para actualizaciones [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) y [@austinywang](https://x.com/austinywang)
- Únete a la conversación en [Discord](https://discord.gg/xsgFEVrWCZ)
- Crea y participa en [GitHub issues](https://github.com/manaflow-ai/cmux/issues) y [discusiones](https://github.com/manaflow-ai/cmux/discussions)
- Cuéntanos qué estás construyendo con cmux

## Comunidad

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux es gratuito, de código abierto, y siempre lo será. Si deseas apoyar el desarrollo y obtener acceso anticipado a lo que viene:

**[Obtener Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Solicitudes de funciones/corrección de errores priorizadas**
- **Acceso anticipado: cmux AI que te da contexto sobre cada espacio de trabajo, pestaña y panel**
- **Acceso anticipado: app de iOS con terminales sincronizadas entre escritorio y teléfono**
- **Acceso anticipado: VMs en la nube**
- **Acceso anticipado: Modo de voz**
- **Mi iMessage/WhatsApp personal**

## Licencia

cmux es código abierto bajo [AGPL-3.0-or-later](LICENSE).

Si su organización no puede cumplir con AGPL, hay una licencia comercial disponible. Contacte a [founders@manaflow.com](mailto:founders@manaflow.com) para más detalles.
