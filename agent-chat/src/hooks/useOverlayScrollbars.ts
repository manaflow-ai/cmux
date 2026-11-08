import { useEffect } from "react";

export function useOverlayScrollbars() {
  useEffect(() => {
    const timers = new WeakMap<HTMLElement, ReturnType<typeof setTimeout>>();
    const onScroll = (e: Event) => {
      const target = e.target instanceof HTMLElement ? e.target : null;
      if (!target) return;
      target.dataset.scrolling = "true";
      const timer = timers.get(target);
      if (timer) clearTimeout(timer);
      timers.set(target, setTimeout(() => {
        delete target.dataset.scrolling;
        timers.delete(target);
      }, 800));
    };
    window.addEventListener("scroll", onScroll, true);
    return () => window.removeEventListener("scroll", onScroll, true);
  }, []);
}
