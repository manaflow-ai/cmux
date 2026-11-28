// Ten simulated tabs: mixed light/dark, same-site pairs and cross-site jumps,
// modelled on Leo's 11-22 video (white PNG file page, dark raw.githubusercontent
// image, dark GitHub PR) plus common sites.
export const PAGES = [
  { id: 0, site: "file",            title: "composer-2.png",        bg: "#ffffff", fg: "#1f2328", theme: null,      scheme: "light", kind: "image-light" },
  { id: 1, site: "raw.githubusercontent.com", title: "mascot.png",  bg: "#1d1c26", fg: "#c9c6d8", theme: null,      scheme: "dark",  kind: "image-dark" },
  { id: 2, site: "github.com",      title: "PR #18039 (dark)",      bg: "#0d1117", fg: "#e6edf3", theme: "#0d1117", scheme: "dark",  kind: "doc" },
  { id: 3, site: "github.com",      title: "PR #18040 (light)",     bg: "#ffffff", fg: "#1f2328", theme: "#ffffff", scheme: "light", kind: "doc" },
  { id: 4, site: "docs.rs",         title: "docs (light)",          bg: "#fafafa", fg: "#222222", theme: "#fafafa", scheme: "light", kind: "doc" },
  { id: 5, site: "docs.rs",         title: "docs (dark)",           bg: "#1e1e1e", fg: "#dddddd", theme: "#1e1e1e", scheme: "dark",  kind: "doc" },
  { id: 6, site: "news.ycombinator.com", title: "Hacker News",      bg: "#f6f6ef", fg: "#000000", theme: "#ff6600", scheme: "light", kind: "list" },
  { id: 7, site: "linear.app",      title: "Linear (brand)",        bg: "#4f46e5", fg: "#ffffff", theme: "#4f46e5", scheme: "dark",  kind: "hero" },
  { id: 8, site: "localhost:3000",  title: "terminal web",          bg: "#000000", fg: "#33ff66", theme: "#000000", scheme: "dark",  kind: "mono" },
  { id: 9, site: "nytimes.com",     title: "paper (beige)",         bg: "#f7f3ea", fg: "#121212", theme: null,      scheme: "light", kind: "doc" },
];
