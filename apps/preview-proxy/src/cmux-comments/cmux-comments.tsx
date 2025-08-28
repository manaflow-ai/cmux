import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { ConvexProvider, ConvexReactClient } from "convex/react";
import { useQuery, useMutation } from "convex/react";
import { api } from "../../../../packages/convex/convex/_generated/api";
// Removed unused lucide-react import since we're using inline SVGs

// Embedded Tailwind CSS with resets
const TAILWIND_STYLES = `
  /* Tailwind CSS Reset and Base */
  *, ::before, ::after {
    box-sizing: border-box;
    border-width: 0;
    border-style: solid;
    border-color: #e5e7eb;
  }
  
  ::before, ::after {
    --tw-content: '';
  }
  
  html, :host {
    line-height: 1.5;
    -webkit-text-size-adjust: 100%;
    -moz-tab-size: 4;
    tab-size: 4;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif;
    font-feature-settings: normal;
    font-variation-settings: normal;
    -webkit-tap-highlight-color: transparent;
  }
  
  body {
    margin: 0;
    line-height: inherit;
  }
  
  hr {
    height: 0;
    color: inherit;
    border-top-width: 1px;
  }
  
  h1, h2, h3, h4, h5, h6 {
    font-size: inherit;
    font-weight: inherit;
  }
  
  a {
    color: inherit;
    text-decoration: inherit;
  }
  
  b, strong {
    font-weight: bolder;
  }
  
  code, kbd, samp, pre {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    font-feature-settings: normal;
    font-variation-settings: normal;
    font-size: 1em;
  }
  
  small {
    font-size: 80%;
  }
  
  table {
    text-indent: 0;
    border-color: inherit;
    border-collapse: collapse;
  }
  
  button, input, optgroup, select, textarea {
    font-family: inherit;
    font-feature-settings: inherit;
    font-variation-settings: inherit;
    font-size: 100%;
    font-weight: inherit;
    line-height: inherit;
    letter-spacing: inherit;
    color: inherit;
    margin: 0;
    padding: 0;
  }
  
  button, select {
    text-transform: none;
  }
  
  button, input {
    background: none;
  }
  
  button, [type='button'], [type='reset'], [type='submit'] {
    -webkit-appearance: button;
    background-color: transparent;
    background-image: none;
  }
  
  :-moz-focusring {
    outline: auto;
  }
  
  :-moz-ui-invalid {
    box-shadow: none;
  }
  
  progress {
    vertical-align: baseline;
  }
  
  ::-webkit-inner-spin-button, ::-webkit-outer-spin-button {
    height: auto;
  }
  
  [type='search'] {
    -webkit-appearance: textfield;
    outline-offset: -2px;
  }
  
  ::-webkit-search-decoration {
    -webkit-appearance: none;
  }
  
  ::-webkit-file-upload-button {
    -webkit-appearance: button;
    font: inherit;
  }
  
  summary {
    display: list-item;
  }
  
  blockquote, dl, dd, h1, h2, h3, h4, h5, h6, hr, figure, p, pre {
    margin: 0;
  }
  
  fieldset {
    margin: 0;
    padding: 0;
  }
  
  legend {
    padding: 0;
  }
  
  ol, ul, menu {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  
  dialog {
    padding: 0;
  }
  
  textarea {
    resize: vertical;
  }
  
  input::placeholder, textarea::placeholder {
    opacity: 1;
    color: #6b7280;
  }
  
  button, [role="button"] {
    cursor: pointer;
  }
  
  :disabled {
    cursor: default;
  }
  
  img, svg, video, canvas, audio, iframe, embed, object {
    display: block;
    vertical-align: middle;
  }
  
  img, video {
    max-width: 100%;
    height: auto;
  }
  
  [hidden] {
    display: none;
  }

  /* Custom styles for the widget */
  .cmux-widget {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
  }

  /* Tailwind utilities */
  .fixed { position: fixed; }
  .absolute { position: absolute; }
  .relative { position: relative; }
  .bottom-4 { bottom: 1rem; }
  .right-4 { right: 1rem; }
  .top-0 { top: 0; }
  .left-0 { left: 0; }
  .z-50 { z-index: 50; }
  .z-\\[9999\\] { z-index: 9999; }
  .z-\\[10000\\] { z-index: 10000; }
  .flex { display: flex; }
  .hidden { display: none; }
  .items-center { align-items: center; }
  .items-start { align-items: flex-start; }
  .gap-1 { gap: 0.25rem; }
  .gap-2 { gap: 0.5rem; }
  .gap-3 { gap: 0.75rem; }
  .h-4 { height: 1rem; }
  .h-5 { height: 1.25rem; }
  .h-6 { height: 1.5rem; }
  .h-7 { height: 1.75rem; }
  .h-8 { height: 2rem; }
  .h-9 { height: 2.25rem; }
  .h-10 { height: 2.5rem; }
  .h-11 { height: 2.75rem; }
  .h-12 { height: 3rem; }
  .h-14 { height: 3.5rem; }
  .h-full { height: 100%; }
  .h-96 { height: 24rem; }
  .w-4 { width: 1rem; }
  .w-5 { width: 1.25rem; }
  .w-6 { width: 1.5rem; }
  .w-7 { width: 1.75rem; }
  .w-8 { width: 2rem; }
  .w-9 { width: 2.25rem; }
  .w-10 { width: 2.5rem; }
  .w-11 { width: 2.75rem; }
  .w-12 { width: 3rem; }
  .w-14 { width: 3.5rem; }
  .w-full { width: 100%; }
  .w-80 { width: 20rem; }
  .min-h-\\[100px\\] { min-height: 100px; }
  .max-h-96 { max-height: 24rem; }
  .cursor-pointer { cursor: pointer; }
  .cursor-move { cursor: move; }
  .cursor-crosshair { cursor: crosshair; }
  .select-none { user-select: none; }
  .flex-col { flex-direction: column; }
  .flex-1 { flex: 1; }
  .justify-center { justify-content: center; }
  .justify-between { justify-content: space-between; }
  .gap-3 { gap: 0.75rem; }
  .gap-4 { gap: 1rem; }
  .space-y-2 > :not([hidden]) ~ :not([hidden]) { margin-top: 0.5rem; }
  .space-y-3 > :not([hidden]) ~ :not([hidden]) { margin-top: 0.75rem; }
  .space-y-4 > :not([hidden]) ~ :not([hidden]) { margin-top: 1rem; }
  .overflow-auto { overflow: auto; }
  .overflow-hidden { overflow: hidden; }
  .overflow-y-auto { overflow-y: auto; }
  .rounded { border-radius: 0.25rem; }
  .rounded-md { border-radius: 0.375rem; }
  .rounded-lg { border-radius: 0.5rem; }
  .rounded-xl { border-radius: 0.75rem; }
  .rounded-2xl { border-radius: 1rem; }
  .rounded-full { border-radius: 9999px; }
  .border { border-width: 1px; }
  .border-2 { border-width: 2px; }
  .border-neutral-200 { border-color: rgb(229 229 229); }
  .border-neutral-300 { border-color: rgb(212 212 212); }
  .border-neutral-700 { border-color: rgb(64 64 64); }
  .border-neutral-800 { border-color: rgb(38 38 38); }
  .border-blue-500 { border-color: rgb(59 130 246); }
  .border-red-500 { border-color: rgb(239 68 68); }
  .bg-white { background-color: rgb(255 255 255); }
  .bg-black { background-color: rgb(0 0 0); }
  .bg-neutral-50 { background-color: rgb(250 250 250); }
  .bg-neutral-100 { background-color: rgb(245 245 245); }
  .bg-neutral-800 { background-color: rgb(38 38 38); }
  .bg-neutral-900 { background-color: rgb(23 23 23); }
  .bg-neutral-950 { background-color: rgb(10 10 10); }
  .bg-blue-500 { background-color: rgb(59 130 246); }
  .bg-blue-600 { background-color: rgb(37 99 235); }
  .bg-red-500 { background-color: rgb(239 68 68); }
  .bg-green-500 { background-color: rgb(34 197 94); }
  .bg-opacity-50 { background-color: rgb(0 0 0 / 0.5); }
  .p-1 { padding: 0.25rem; }
  .p-2 { padding: 0.5rem; }
  .p-3 { padding: 0.75rem; }
  .p-4 { padding: 1rem; }
  .p-5 { padding: 1.25rem; }
  .px-2 { padding-left: 0.5rem; padding-right: 0.5rem; }
  .px-3 { padding-left: 0.75rem; padding-right: 0.75rem; }
  .px-4 { padding-left: 1rem; padding-right: 1rem; }
  .px-5 { padding-left: 1.25rem; padding-right: 1.25rem; }
  .py-1 { padding-top: 0.25rem; padding-bottom: 0.25rem; }
  .py-2 { padding-top: 0.5rem; padding-bottom: 0.5rem; }
  .py-3 { padding-top: 0.75rem; padding-bottom: 0.75rem; }
  .py-4 { padding-top: 1rem; padding-bottom: 1rem; }
  .pl-4 { padding-left: 1rem; }
  .pr-12 { padding-right: 3rem; }
  .text-xs { font-size: 0.75rem; line-height: 1rem; }
  .text-sm { font-size: 0.875rem; line-height: 1.25rem; }
  .text-base { font-size: 1rem; line-height: 1.5rem; }
  .text-lg { font-size: 1.125rem; line-height: 1.75rem; }
  .font-normal { font-weight: 400; }
  .font-medium { font-weight: 500; }
  .font-semibold { font-weight: 600; }
  .text-white { color: rgb(255 255 255); }
  .text-neutral-400 { color: rgb(163 163 163); }
  .text-neutral-500 { color: rgb(115 115 115); }
  .text-neutral-600 { color: rgb(82 82 82); }
  .text-neutral-700 { color: rgb(64 64 64); }
  .text-neutral-900 { color: rgb(23 23 23); }
  .placeholder-neutral-500::placeholder { color: rgb(115 115 115); }
  .placeholder-neutral-600::placeholder { color: rgb(82 82 82); }
  .shadow { box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1); }
  .shadow-md { box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); }
  .shadow-lg { box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1); }
  .shadow-xl { box-shadow: 0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1); }
  .shadow-2xl { box-shadow: 0 25px 50px -12px rgb(0 0 0 / 0.25); }
  .ring-2 { box-shadow: 0 0 0 2px var(--tw-ring-color); }
  .ring-blue-500 { --tw-ring-color: rgb(59 130 246); }
  .ring-offset-2 { box-shadow: 0 0 0 2px #fff, 0 0 0 4px var(--tw-ring-color); }
  .transition { transition-property: all; transition-timing-function: cubic-bezier(0.4, 0, 0.2, 1); transition-duration: 150ms; }
  .transition-all { transition-property: all; transition-timing-function: cubic-bezier(0.4, 0, 0.2, 1); transition-duration: 150ms; }
  .transition-opacity { transition-property: opacity; transition-timing-function: cubic-bezier(0.4, 0, 0.2, 1); transition-duration: 150ms; }
  .transition-transform { transition-property: transform; transition-timing-function: cubic-bezier(0.4, 0, 0.2, 1); transition-duration: 150ms; }
  .duration-200 { transition-duration: 200ms; }
  .duration-300 { transition-duration: 300ms; }
  .hover\\:bg-neutral-100:hover { background-color: rgb(245 245 245); }
  .hover\\:bg-neutral-800:hover { background-color: rgb(38 38 38); }
  .hover\\:bg-blue-600:hover { background-color: rgb(37 99 235); }
  .hover\\:bg-red-600:hover { background-color: rgb(220 38 38); }
  .hover\\:shadow-lg:hover { box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1); }
  .hover\\:scale-105:hover { transform: scale(1.05); }
  .hover\\:scale-110:hover { transform: scale(1.1); }
  .focus\\:outline-none:focus { outline: 2px solid transparent; outline-offset: 2px; }
  .focus\\:ring-2:focus { box-shadow: 0 0 0 2px var(--tw-ring-color); }
  .focus\\:ring-blue-500:focus { --tw-ring-color: rgb(59 130 246); }
  .animate-pulse { animation: pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
  }
  .pointer-events-none { pointer-events: none; }
  .pointer-events-auto { pointer-events: auto; }
  .resize-none { resize: none; }
  .break-words { word-break: break-word; }
  .opacity-0 { opacity: 0; }
  .opacity-50 { opacity: 0.5; }
  .opacity-60 { opacity: 0.6; }
  .opacity-70 { opacity: 0.7; }
  .opacity-100 { opacity: 1; }
  .scale-95 { transform: scale(0.95); }
  .scale-100 { transform: scale(1); }
  
  /* Custom gradient backgrounds */
  .bg-gradient-primary {
    background: linear-gradient(135deg, #ec4899 0%, #db2777 100%);
  }
  
  .bg-gradient-blue {
    background: linear-gradient(135deg, #ec4899 0%, #db2777 100%);
  }
  
  /* Icon container styles */
  .icon-button {
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s;
  }
  
  .icon-button:hover {
    transform: scale(1.1);
  }
  
  .icon-button:active {
    transform: scale(0.95);
  }
  
  /* Comment input styling */
  .comment-input {
    background: transparent;
    border: none;
    outline: none;
    width: 100%;
    color: white;
    font-size: 15px;
    line-height: 1.5;
  }
  
  .comment-input::placeholder {
    color: rgb(107 114 128);
  }
  
  /* Backdrop blur effect */
  .backdrop-blur {
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
  }
  
  /* Custom scrollbar */
  .custom-scrollbar::-webkit-scrollbar {
    width: 6px;
  }
  
  .custom-scrollbar::-webkit-scrollbar-track {
    background: transparent;
  }
  
  .custom-scrollbar::-webkit-scrollbar-thumb {
    background: rgb(64 64 64);
    border-radius: 3px;
  }
  
  .custom-scrollbar::-webkit-scrollbar-thumb:hover {
    background: rgb(82 82 82);
  }
`;

// Lucide icon components with embedded SVG
const SendIcon = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>
  </svg>
);

const PlusIcon = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M5 12h14"/><path d="m12 5 0 14"/>
  </svg>
);

const ImageIcon = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>
  </svg>
);

const TypeIcon = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <polyline points="4 7 4 4 20 4 20 7"/><line x1="9" x2="15" y1="20" y2="20"/><line x1="12" x2="12" y1="4" y2="20"/>
  </svg>
);

const MessageIcon = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>
  </svg>
);

interface Comment {
  _id: string;
  url: string;
  page: string;
  pageTitle: string;
  nodeId: string;
  x: number;
  y: number;
  content: string;
  resolved?: boolean;
  userId: string;
  profileImageUrl?: string;
  userAgent: string;
  screenWidth: number;
  screenHeight: number;
  devicePixelRatio: number;
  createdAt: number;
  updatedAt: number;
}

interface CommentMarkerProps {
  comment: Comment;
  onClick: () => void;
}

function CommentMarker({ comment, onClick }: CommentMarkerProps) {
  const [position, setPosition] = useState<{ x: number; y: number } | null>(null);

  useEffect(() => {
    const updatePosition = () => {
      try {
        let el: HTMLElement | null = null;
        
        // Check if it's an XPath (starts with /) or old CSS selector
        if (comment.nodeId.startsWith('/')) {
          // It's an XPath
          const result = document.evaluate(
            comment.nodeId, 
            document, 
            null, 
            XPathResult.FIRST_ORDERED_NODE_TYPE, 
            null
          );
          el = result.singleNodeValue as HTMLElement;
        } else {
          // Old CSS selector - try to handle it
          try {
            el = document.querySelector(comment.nodeId) as HTMLElement;
          } catch (_e) {
            // Try escaping for old Tailwind classes
            const escapedSelector = comment.nodeId.replace(/([:])/g, '\\$1');
            try {
              el = document.querySelector(escapedSelector) as HTMLElement;
            } catch (_e2) {
              console.warn(`Could not find element with CSS selector: ${comment.nodeId}`);
            }
          }
        }
        
        if (el) {
          const rect = el.getBoundingClientRect();
          const x = rect.left + rect.width * comment.x;
          const y = rect.top + rect.height * comment.y;
          setPosition({ x, y });
        } else {
          setPosition(null);
        }
      } catch (e) {
        console.error("Failed to find element for comment:", e, "NodeId:", comment.nodeId);
        setPosition(null);
      }
    };

    // Update position initially
    updatePosition();

    // Update position on scroll and resize
    window.addEventListener('scroll', updatePosition, true);
    window.addEventListener('resize', updatePosition);
    
    // Update position when DOM changes
    const observer = new MutationObserver(updatePosition);
    observer.observe(document.body, { 
      childList: true, 
      subtree: true,
      attributes: true 
    });

    return () => {
      window.removeEventListener('scroll', updatePosition, true);
      window.removeEventListener('resize', updatePosition);
      observer.disconnect();
    };
  }, [comment.nodeId, comment.x, comment.y]);

  if (!position) return null;

  return (
    <div
      className="fixed w-8 h-8 bg-gradient-blue rounded-full flex items-center justify-center text-white cursor-pointer shadow-lg z-[9999] transition-all duration-200 hover:scale-110"
      style={{
        left: `${position.x - 16}px`,
        top: `${position.y - 16}px`,
      }}
      onClick={onClick}
    >
      <MessageIcon />
    </div>
  );
}

function CmuxCommentsWidget() {
  const [isOpen, setIsOpen] = useState(false);
  const [isCommenting, setIsCommenting] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const [position, setPosition] = useState({ x: window.innerWidth - 400, y: window.innerHeight - 500 });
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 });
  const [commentDraft, setCommentDraft] = useState("");
  const [commentInputPos, setCommentInputPos] = useState<{ x: number; y: number } | null>(null);
  const [pendingCommentData, setPendingCommentData] = useState<{
    url: string;
    page: string;
    pageTitle: string;
    nodeId: string;
    x: number;
    y: number;
    profileImageUrl?: string;
    userAgent: string;
    screenWidth: number;
    screenHeight: number;
    devicePixelRatio: number;
  } | null>(null);
  const [cursorPos, setCursorPos] = useState({ x: 0, y: 0 });
  const widgetRef = useRef<HTMLDivElement>(null);
  const commentInputRef = useRef<HTMLTextAreaElement>(null);

  const comments = useQuery(api.comments.listComments, {
    url: window.location.origin,
    page: window.location.pathname,
  });

  const createComment = useMutation(api.comments.createComment);

  // Handle cursor tracking when commenting
  useEffect(() => {
    if (!isCommenting) return;
    
    const handleMouseMove = (e: MouseEvent) => {
      setCursorPos({ x: e.clientX, y: e.clientY });
    };
    
    document.addEventListener('mousemove', handleMouseMove);
    return () => document.removeEventListener('mousemove', handleMouseMove);
  }, [isCommenting]);

  // Handle keyboard shortcut
  useEffect(() => {
    const handleKeyPress = (e: KeyboardEvent) => {
      if (e.key === "c" && !e.ctrlKey && !e.metaKey && !e.altKey) {
        const target = e.target as HTMLElement;
        if (target.tagName !== "INPUT" && target.tagName !== "TEXTAREA") {
          e.preventDefault();
          setIsCommenting(true);
        }
      }
      if (e.key === "Escape") {
        setIsCommenting(false);
        setPendingCommentData(null);
        setCommentInputPos(null);
      }
    };

    document.addEventListener("keydown", handleKeyPress);
    return () => document.removeEventListener("keydown", handleKeyPress);
  }, []);

  // Handle single click commenting
  useEffect(() => {
    if (!isCommenting) return;

    const handleClick = async (e: MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      
      const element = e.target as HTMLElement;
      
      // Don't create comments on the widget itself or comment input
      if (element.closest("#cmux-comments-root")) return;
      
      const rect = element.getBoundingClientRect();
      const x = (e.clientX - rect.left) / rect.width;
      const y = (e.clientY - rect.top) / rect.height;
      
      // Generate XPath for the element
      const getXPath = (el: Element): string => {
        if (el.id) {
          return `//*[@id="${el.id}"]`;
        }
        
        const paths: string[] = [];
        let current: Element | null = el;
        
        while (current && current.nodeType === Node.ELEMENT_NODE) {
          let index = 0;
          let sibling = current.previousSibling;
          
          while (sibling) {
            if (sibling.nodeType === Node.ELEMENT_NODE && 
                sibling.nodeName === current.nodeName) {
              index++;
            }
            sibling = sibling.previousSibling;
          }
          
          const tagName = current.nodeName.toLowerCase();
          const pathIndex = index > 0 ? `[${index + 1}]` : '';
          paths.unshift(`${tagName}${pathIndex}`);
          
          current = current.parentElement;
        }
        
        return '/' + paths.join('/');
      };

      const nodeId = getXPath(element);
      
      // Store the comment data
      const commentData = {
        url: window.location.origin,
        page: window.location.pathname,
        pageTitle: document.title,
        nodeId,
        x,
        y,
        profileImageUrl: undefined, // This would come from auth/user context
        userAgent: navigator.userAgent,
        screenWidth: window.innerWidth,
        screenHeight: window.innerHeight,
        devicePixelRatio: window.devicePixelRatio,
      };
      
      setPendingCommentData(commentData);
      setCommentInputPos({ x: e.clientX, y: e.clientY });
      setIsCommenting(false);
      
      // Focus the input after it renders
      setTimeout(() => {
        commentInputRef.current?.focus();
      }, 50);
    };

    document.addEventListener("click", handleClick, true);

    return () => {
      document.removeEventListener("click", handleClick, true);
    };
  }, [isCommenting]);

  // Handle dragging
  const handleMouseDown = (e: React.MouseEvent) => {
    if ((e.target as HTMLElement).closest(".widget-header")) {
      setIsDragging(true);
      setDragStart({ x: e.clientX - position.x, y: e.clientY - position.y });
    }
  };

  useEffect(() => {
    if (!isDragging) return;

    const handleMouseMove = (e: MouseEvent) => {
      setPosition({
        x: e.clientX - dragStart.x,
        y: e.clientY - dragStart.y,
      });
    };

    const handleMouseUp = () => {
      setIsDragging(false);
    };

    document.addEventListener("mousemove", handleMouseMove);
    document.addEventListener("mouseup", handleMouseUp);

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
    };
  }, [isDragging, dragStart]);

  const handleSubmitComment = async () => {
    if (!pendingCommentData || !commentDraft.trim()) return;

    await createComment({
      ...pendingCommentData,
      content: commentDraft,
      userId: "anonymous", // You'd get this from auth
      profileImageUrl: pendingCommentData.profileImageUrl,
    });

    setCommentDraft("");
    setPendingCommentData(null);
    setCommentInputPos(null);
  };
  
  const handleCancelComment = () => {
    setCommentDraft("");
    setPendingCommentData(null);
    setCommentInputPos(null);
  };

  return (
    <div className="cmux-widget">
      {/* Comment markers */}
      {comments?.map((comment: Comment) => (
        <CommentMarker
          key={comment._id}
          comment={comment}
          onClick={() => setIsOpen(true)}
        />
      ))}

      {/* Cursor indicator when in commenting mode - simple tooltip */}
      {isCommenting && (
        <div
          className="fixed z-[10000] pointer-events-none"
          style={{
            left: `${cursorPos.x + 10}px`,
            top: `${cursorPos.y - 10}px`,
          }}
        >
          <div className="bg-blue-500 text-white px-3 py-1 rounded-full text-sm shadow-lg animate-pulse">
            Click to comment
          </div>
        </div>
      )}

      {/* Comment input popup - styled like the screenshot */}
      {commentInputPos && pendingCommentData && (
        <div
          className="fixed z-[10000] rounded-2xl shadow-2xl backdrop-blur"
          style={{
            left: `${Math.min(commentInputPos.x - 50, window.innerWidth - 420)}px`,
            top: `${Math.min(commentInputPos.y + 20, window.innerHeight - 200)}px`,
            width: "400px",
            background: "rgba(17, 17, 17, 0.95)",
            border: "1px solid rgba(255, 255, 255, 0.1)",
          }}
        >
          <div className="p-4">
            <div className="flex items-start gap-3">
              {/* Avatar placeholder */}
              <div className="flex-shrink-0">
                {pendingCommentData?.profileImageUrl ? (
                  <img
                    src={pendingCommentData.profileImageUrl}
                    alt="User avatar"
                    className="w-10 h-10 rounded-full"
                  />
                ) : (
                  <div className="w-10 h-10 rounded-full bg-gradient-blue flex items-center justify-center text-white font-medium">
                    U
                  </div>
                )}
              </div>
              
              {/* Input area */}
              <div className="flex-1">
                <textarea
                  ref={commentInputRef}
                  value={commentDraft}
                  onChange={(e) => setCommentDraft(e.target.value)}
                  placeholder="Start a new thread..."
                  className="comment-input"
                  style={{ minHeight: "60px" }}
                  autoFocus
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
                      handleSubmitComment();
                    }
                    if (e.key === "Escape") {
                      handleCancelComment();
                    }
                  }}
                />
                
                {/* Bottom toolbar */}
                <div className="flex items-center justify-between mt-3">
                  <div className="flex items-center gap-1">
                    <button className="icon-button w-8 h-8 rounded-lg hover:bg-neutral-800 text-neutral-400">
                      <PlusIcon />
                    </button>
                    <button className="icon-button w-8 h-8 rounded-lg hover:bg-neutral-800 text-neutral-400">
                      <ImageIcon />
                    </button>
                    <div className="w-px h-5 bg-neutral-700 mx-1"></div>
                    <button className="icon-button w-8 h-8 rounded-lg hover:bg-neutral-800 text-neutral-400">
                      <TypeIcon />
                    </button>
                  </div>
                  
                  {/* Send button */}
                  <button
                    onClick={handleSubmitComment}
                    disabled={!commentDraft.trim()}
                    className={`icon-button w-9 h-9 rounded-lg transition-all ${
                      commentDraft.trim() 
                        ? "bg-blue-500 text-white hover:bg-blue-600" 
                        : "bg-neutral-800 text-neutral-500 cursor-not-allowed"
                    }`}
                  >
                    <SendIcon />
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Floating widget */}
      <div
        ref={widgetRef}
        className={`fixed z-[9999] rounded-2xl shadow-2xl transition-all duration-300 backdrop-blur ${
          isOpen ? "opacity-100 scale-100" : "opacity-0 scale-95 pointer-events-none"
        }`}
        style={{
          left: `${position.x}px`,
          top: `${position.y}px`,
          width: "380px",
          background: "rgba(17, 17, 17, 0.95)",
          border: "1px solid rgba(255, 255, 255, 0.1)",
        }}
        onMouseDown={handleMouseDown}
      >
        {/* Header */}
        <div className="widget-header flex items-center justify-between p-4 cursor-move select-none border-b" style={{ borderColor: "rgba(255, 255, 255, 0.1)" }}>
          <h3 className="text-base font-medium text-white">Comments</h3>
          <button
            onClick={() => setIsOpen(false)}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-neutral-400 hover:bg-neutral-800 transition-all"
          >
            ✕
          </button>
        </div>

        {/* Content */}
        <div className="p-4 max-h-96 overflow-y-auto custom-scrollbar">
          <div className="space-y-3">
            {comments?.length === 0 ? (
              <p className="text-neutral-400 text-sm text-center py-8">
                No comments yet. Press "C" to add one!
              </p>
            ) : (
              comments?.map((comment: Comment) => (
                <div key={comment._id} className="flex items-start gap-3">
                  {comment.profileImageUrl ? (
                    <img
                      src={comment.profileImageUrl}
                      alt="User avatar"
                      className="w-8 h-8 rounded-full flex-shrink-0"
                    />
                  ) : (
                    <div className="w-8 h-8 rounded-full bg-gradient-blue flex items-center justify-center text-white text-xs font-medium flex-shrink-0">
                      U
                    </div>
                  )}
                  <div className="flex-1">
                    <p className="text-sm text-white break-words">{comment.content}</p>
                    <p className="text-xs text-neutral-500 mt-1">
                      {new Date(comment.createdAt).toLocaleString()}
                    </p>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>

      {/* Floating button */}
      {!isOpen && (
        <button
          onClick={() => setIsOpen(true)}
          className="fixed bottom-4 right-4 w-14 h-14 bg-gradient-blue rounded-full flex items-center justify-center text-white shadow-2xl transition-all duration-300 hover:scale-110 z-[9999]"
        >
          <MessageIcon />
        </button>
      )}
    </div>
  );
}

// Initialize the widget
export function initCmuxComments(convexUrl?: string) {
  // Create shadow root container
  const container = document.createElement("div");
  container.id = "cmux-comments-root";
  container.style.position = "fixed";
  container.style.top = "0";
  container.style.left = "0";
  container.style.width = "0";
  container.style.height = "0";
  container.style.zIndex = "999999";
  document.body.appendChild(container);

  // Create shadow root
  const shadowRoot = container.attachShadow({ mode: "open" });

  // Add styles
  const styleSheet = document.createElement("style");
  styleSheet.textContent = TAILWIND_STYLES;
  shadowRoot.appendChild(styleSheet);

  // Create React root container
  const reactContainer = document.createElement("div");
  shadowRoot.appendChild(reactContainer);

  // Get Convex URL from environment or parameter
  const CONVEX_URL = convexUrl || process.env.NEXT_PUBLIC_CONVEX_URL || process.env.VITE_CONVEX_URL || "";
  
  if (!CONVEX_URL) {
    console.error("Convex URL not provided. Please set NEXT_PUBLIC_CONVEX_URL or pass it to initCmuxComments()");
    return;
  }

  // Initialize Convex client
  const convex = new ConvexReactClient(CONVEX_URL);

  // Render React app
  const root = createRoot(reactContainer);
  root.render(
    <ConvexProvider client={convex}>
      <CmuxCommentsWidget />
    </ConvexProvider>
  );

  // Return cleanup function
  return () => {
    root.unmount();
    container.remove();
  };
}

// Auto-initialize if script tag has data-auto-init
if (typeof window !== "undefined") {
  const script = document.currentScript as HTMLScriptElement;
  if (script?.dataset.autoInit === "true") {
    const convexUrl = script.dataset.convexUrl;
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", () => initCmuxComments(convexUrl));
    } else {
      initCmuxComments(convexUrl);
    }
  }
}

// Export for manual initialization
declare global {
  interface Window {
    CmuxComments: {
      init: (convexUrl?: string) => (() => void) | undefined;
    };
  }
}

if (typeof window !== "undefined") {
  window.CmuxComments = { init: initCmuxComments };
}