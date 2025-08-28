import { useSocket } from "@/contexts/socket/use-socket";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import type { SpawnFromComment } from "@cmux/shared";
import clsx from "clsx";
import { useMutation, useQuery } from "convex/react";
import React, { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

const PlusIcon = ({ className }: { className?: string }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="20"
    height="20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
  >
    <path d="M5 12h14" />
    <path d="m12 5 0 14" />
  </svg>
);

const ImageIcon = ({ className }: { className?: string }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="20"
    height="20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
  >
    <rect width="18" height="18" x="3" y="3" rx="2" ry="2" />
    <circle cx="9" cy="9" r="2" />
    <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
  </svg>
);

const TypeIcon = ({ className }: { className?: string }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="20"
    height="20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
  >
    <polyline points="4 7 4 4 20 4 20 7" />
    <line x1="9" x2="15" y1="20" y2="20" />
    <line x1="12" x2="12" y1="4" y2="20" />
  </svg>
);

const MessageIcon = ({ className }: { className?: string }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="20"
    height="20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
  >
    <path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z" />
  </svg>
);

const ArchiveIcon = ({ className }: { className?: string }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
  >
    <rect width="20" height="5" x="2" y="3" rx="1" />
    <path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8" />
    <path d="M10 12h4" />
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
  archived?: boolean;
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

// Helper function to render markdown links
function renderMarkdownLinks(text: string): React.ReactNode {
  // Match markdown links [text](url)
  const linkRegex = /\[([^\]]+)\]\(([^)]+)\)/g;
  const parts: React.ReactNode[] = [];
  let lastIndex = 0;
  let match;

  while ((match = linkRegex.exec(text)) !== null) {
    // Add text before the link
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }

    // Add the link
    const linkText = match[1];
    const linkUrl = match[2];
    parts.push(
      <a
        key={match.index}
        href={linkUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="text-blue-400 hover:text-blue-300 underline"
      >
        {linkText}
      </a>
    );

    lastIndex = match.index + match[0].length;
  }

  // Add remaining text
  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return parts.length > 0 ? parts : text;
}

// Component to display comment replies
function CommentReplies({ commentId }: { commentId: Id<"comments"> }) {
  const replies = useQuery(api.comments.getReplies, { commentId });

  if (!replies || replies.length === 0) {
    return null;
  }

  return (
    <div className="mt-3 ml-2.5 border-l-2 border-neutral-700 pl-5 space-y-2">
      {replies.map((reply) => (
        <div key={reply._id} className="flex items-start gap-2">
          <div className="w-6 h-6 rounded-full bg-gradient-to-br from-pink-500 to-pink-600 flex items-center justify-center text-white text-xs font-medium flex-shrink-0">
            {reply.userId === "cmux" ? "C" : "U"}
          </div>
          <div className="flex-1">
            <p className="text-sm text-neutral-200 break-words">
              {renderMarkdownLinks(reply.content)}
            </p>
            <p className="text-xs text-neutral-500 mt-1">
              {new Date(reply.createdAt).toLocaleString()}
            </p>
          </div>
        </div>
      ))}
    </div>
  );
}

function CommentMarker({ comment, onClick }: CommentMarkerProps) {
  const [position, setPosition] = useState<{ x: number; y: number } | null>(
    null
  );
  const [showContent, setShowContent] = useState(true);

  useEffect(() => {
    const updatePosition = () => {
      try {
        let el: HTMLElement | null = null;

        // Check if it's an XPath (starts with /) or old CSS selector
        if (comment.nodeId.startsWith("/")) {
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
            const escapedSelector = comment.nodeId.replace(/([:])/g, "\\$1");
            try {
              el = document.querySelector(escapedSelector) as HTMLElement;
            } catch (_e2) {
              console.warn(
                `Could not find element with CSS selector: ${comment.nodeId}`
              );
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
        console.error(
          "Failed to find element for comment:",
          e,
          "NodeId:",
          comment.nodeId
        );
        setPosition(null);
      }
    };

    // Update position initially
    updatePosition();

    // Update position on scroll and resize
    window.addEventListener("scroll", updatePosition, true);
    window.addEventListener("resize", updatePosition);

    // Update position when DOM changes (but ignore hover-related attribute changes)
    const observer = new MutationObserver((mutations) => {
      // Skip updates if only style/class attributes changed (likely hover effects)
      const shouldUpdate = mutations.some((mutation) => {
        if (mutation.type === "childList") return true;
        if (mutation.type === "attributes") {
          // Ignore common hover-related attributes
          const ignoredAttrs = ["style", "class", "data-hover"];
          return !ignoredAttrs.includes(mutation.attributeName || "");
        }
        return false;
      });

      if (shouldUpdate) {
        updatePosition();
      }
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["id", "data-comment-anchor"], // Only watch specific attributes
    });

    return () => {
      window.removeEventListener("scroll", updatePosition, true);
      window.removeEventListener("resize", updatePosition);
      observer.disconnect();
    };
  }, [comment.nodeId, comment.x, comment.y]);

  if (!position) return null;

  return (
    <>
      {/* Comment marker dot */}
      <div
        className="fixed w-8 h-8 bg-gradient-to-br from-pink-500 to-pink-600 rounded-full flex items-center justify-center text-white cursor-pointer shadow-lg z-[9999] transition-all duration-200"
        style={{
          left: 0,
          top: 0,
          transform: `translate(${position.x - 16}px, ${position.y - 16}px)`,
        }}
        onClick={() => {
          setShowContent(!showContent);
          onClick();
        }}
      >
        <MessageIcon />
      </div>

      {/* Comment content bubble */}
      {showContent && (
        <div
          className="fixed z-[9998] rounded-xl shadow-2xl backdrop-blur-md pointer-events-auto"
          style={{
            left: 0,
            top: 0,
            transform: (() => {
              const bubbleWidth = 320;
              const bubbleHeight = 400;
              const markerRadius = 16; // The marker is 32px (w-8 h-8) with center at position
              const gap = 4; // Small gap between marker and bubble

              // The actual bounds of the marker (it's centered at position.x, position.y)
              const markerLeft = position.x - markerRadius;
              const markerRight = position.x + markerRadius;
              const markerTop = position.y - markerRadius;
              const markerBottom = position.y + markerRadius;

              // Calculate potential positions with gap
              const bottomY = markerBottom + gap;
              const rightX = markerRight + gap;
              const leftX = markerLeft - bubbleWidth - gap;
              const topY = markerTop - bubbleHeight - gap;

              // Check available space
              const hasSpaceBottom =
                bottomY + bubbleHeight <= window.innerHeight;
              const hasSpaceRight = rightX + bubbleWidth <= window.innerWidth;
              const hasSpaceLeft = leftX >= 0;
              const hasSpaceTop = topY >= 0;

              let x, y;

              // Priority: bottom first, then right, left, top
              if (hasSpaceBottom) {
                // Place directly below marker, centered
                x = Math.max(
                  0,
                  Math.min(
                    position.x - bubbleWidth / 2,
                    window.innerWidth - bubbleWidth
                  )
                );
                y = bottomY;
              } else if (hasSpaceRight) {
                // Place to the right of marker
                x = rightX;
                y = Math.max(
                  0,
                  Math.min(
                    position.y - bubbleHeight / 3,
                    window.innerHeight - bubbleHeight
                  )
                );
              } else if (hasSpaceLeft) {
                // Place to the left of marker
                x = leftX;
                y = Math.max(
                  0,
                  Math.min(
                    position.y - bubbleHeight / 3,
                    window.innerHeight - bubbleHeight
                  )
                );
              } else if (hasSpaceTop) {
                // Place above marker, centered
                x = Math.max(
                  0,
                  Math.min(
                    position.x - bubbleWidth / 2,
                    window.innerWidth - bubbleWidth
                  )
                );
                y = topY;
              } else {
                // Fallback: place below with scroll
                x = Math.max(
                  0,
                  Math.min(
                    position.x - bubbleWidth / 2,
                    window.innerWidth - bubbleWidth
                  )
                );
                y = bottomY;
              }

              return `translate(${x}px, ${y}px)`;
            })(),
            width: "320px",
            maxHeight: "400px",
            background: "rgba(17, 17, 17, 0.95)",
            border: "1px solid rgba(255, 255, 255, 0.1)",
          }}
        >
          <div className="p-3 max-h-[380px] overflow-y-auto">
            <div className="flex items-start gap-2">
              {comment.profileImageUrl ? (
                <img
                  src={comment.profileImageUrl}
                  alt="User avatar"
                  className="w-6 h-6 rounded-full flex-shrink-0"
                />
              ) : (
                <div className="w-6 h-6 rounded-full bg-gradient-to-br from-pink-500 to-pink-600 flex items-center justify-center text-white text-xs font-medium flex-shrink-0">
                  U
                </div>
              )}
              <div className="flex-1">
                <p className="text-sm text-white break-words">
                  {comment.content}
                </p>
                <p className="text-xs text-neutral-500 mt-1">
                  {new Date(comment.createdAt).toLocaleString()}
                </p>
              </div>

              <button
                onClick={(e) => {
                  e.stopPropagation();
                  setShowContent(false);
                }}
                className="w-6 h-6 rounded flex items-center justify-center text-neutral-400 hover:bg-neutral-800 transition-all"
              >
                ✕
              </button>
            </div>
            {/* Always show replies in anchored comment */}
            <CommentReplies commentId={comment._id as Id<"comments">} />
          </div>
        </div>
      )}
    </>
  );
}

export function CmuxComments() {
  const { socket } = useSocket();
  const [isOpen, setIsOpen] = useState(false);
  const [isCommenting, setIsCommenting] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const [position, setPosition] = useState({
    x: window.innerWidth / 2 - 190, // Center horizontally (380px width / 2)
    y: window.innerHeight / 2 - 250, // Center vertically (approximate height)
  });
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 });
  const [commentDraft, setCommentDraft] = useState("");
  const [commentInputPos, setCommentInputPos] = useState<{
    x: number;
    y: number;
  } | null>(null);
  const [pendingCommentData, setPendingCommentData] = useState<{
    url: string;
    page: string;
    pageTitle: string;
    nodeId: string;
    x: number;
    y: number;
    userAgent: string;
    screenWidth: number;
    screenHeight: number;
    devicePixelRatio: number;
  } | null>(null);
  const [cursorPos, setCursorPos] = useState({ x: 0, y: 0 });
  const [forceShow, setForceShow] = useState(false);
  const [showArchived, setShowArchived] = useState(false);
  const widgetRef = useRef<HTMLDivElement>(null);
  const commentInputRef = useRef<HTMLTextAreaElement>(null);

  const comments = useQuery(api.comments.listComments, {
    url: window.location.origin,
    page: window.location.pathname,
    includeArchived: showArchived,
  });

  const createComment = useMutation(api.comments.createComment);
  const archiveComment = useMutation(api.comments.archiveComment);

  // Handle cursor tracking when commenting
  useEffect(() => {
    if (!isCommenting) return;

    const handleMouseMove = (e: MouseEvent) => {
      setCursorPos({ x: e.clientX, y: e.clientY });
    };

    document.addEventListener("mousemove", handleMouseMove);
    return () => document.removeEventListener("mousemove", handleMouseMove);
  }, [isCommenting]);

  // Handle keyboard shortcut
  useEffect(() => {
    const handleKeyPress = (e: KeyboardEvent) => {
      // Option+C on Mac produces "ç", so we check for that
      if (e.key === "ç") {
        e.preventDefault();
        setForceShow(!forceShow);
        if (!forceShow) {
          setIsOpen(true);
        }
      }
      // Regular C to enter comment mode
      else if (e.key === "c" && !e.ctrlKey && !e.metaKey && !e.altKey) {
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
  }, [forceShow, isOpen]);

  // Handle single click commenting
  useEffect(() => {
    if (!isCommenting) return;

    const handleClick = async (e: MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();

      const element = e.target as HTMLElement;

      // Don't create comments on the comment widgets themselves
      if (element.closest("[data-cmux-comment-widget]")) return;

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
            if (
              sibling.nodeType === Node.ELEMENT_NODE &&
              sibling.nodeName === current.nodeName
            ) {
              index++;
            }
            sibling = sibling.previousSibling;
          }

          const tagName = current.nodeName.toLowerCase();
          const pathIndex = index > 0 ? `[${index + 1}]` : "";
          paths.unshift(`${tagName}${pathIndex}`);

          current = current.parentElement;
        }

        return "/" + paths.join("/");
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

  // const _user = useUser();
  const userId = "a133a69b-cc28-4bef-8409-cb3a9ae7b208";
  const profileImageUrl =
    "https://avatars.githubusercontent.com/u/54008264?v=4";

  const handleSubmitComment = async () => {
    if (!pendingCommentData || !commentDraft.trim()) return;
    // const userId = user.id;

    // Create the comment in Convex
    const commentId = await createComment({
      ...pendingCommentData,
      content: commentDraft,
      userId,
      // profileImageUrl: user.profileImageUrl || undefined,
      profileImageUrl,
    });

    // Spawn agents via socket.io to address the comment
    if (socket) {
      const spawnData: SpawnFromComment = {
        ...pendingCommentData,
        content: commentDraft,
        userId,
        // profileImageUrl: user.profileImageUrl || undefined,
        profileImageUrl,
        selectedAgents: ["claude/sonnet-4", "codex/gpt-5"],
        commentId,
      };

      socket.emit("spawn-from-comment", spawnData, (response) => {
        if (response.success) {
          console.log("Agents spawned successfully:", response);
          // Optionally navigate to the task page
          if (response.taskId) {
            // Could navigate to /task/{taskId} if desired
            console.log("Task created:", response.taskId);
          }
        } else {
          console.error("Failed to spawn agents:", response.error);
          // Optionally show an error notification
        }
      });
    }

    setCommentDraft("");
    setPendingCommentData(null);
    setCommentInputPos(null);
  };

  const handleCancelComment = () => {
    setCommentDraft("");
    setPendingCommentData(null);
    setCommentInputPos(null);
  };

  // Only render if NOT on localhost:5173 OR if force shown with Option+C
  const shouldRender = () => {
    const hostname = window.location.hostname;
    const port = window.location.port;
    const isLocalhost5173 = hostname === "localhost" && port === "5173";
    return !isLocalhost5173 || forceShow;
  };

  if (!shouldRender()) {
    return null;
  }

  return createPortal(
    <>
      {/* Comment markers - only show non-archived markers on the page */}
      {comments
        ?.filter((c) => !c.archived)
        .map((comment: Comment) => (
          <CommentMarker
            key={comment._id}
            comment={comment}
            onClick={() => {
              setIsOpen(true);
              setForceShow(true);
            }}
          />
        ))}

      {/* Cursor indicator when in commenting mode - simple tooltip */}
      {isCommenting && (
        <div
          className="fixed z-[10000] pointer-events-none"
          style={{
            left: 0,
            top: 0,
            transform: `translate(${cursorPos.x + 10}px, ${cursorPos.y - 10}px)`,
          }}
        >
          <div className="bg-blue-500 text-white px-3 py-1 rounded-full text-sm shadow-lg animate-pulse select-none">
            Click to comment
          </div>
        </div>
      )}

      {/* Comment input popup */}
      {commentInputPos && pendingCommentData && (
        <div
          className="fixed z-[10000] rounded-2xl shadow-2xl backdrop-blur-md"
          data-cmux-comment-widget="true"
          style={{
            left: 0,
            top: 0,
            transform: `translate(${Math.min(commentInputPos.x - 50, window.innerWidth - 420)}px, ${Math.min(commentInputPos.y + 20, window.innerHeight - 200)}px)`,
            width: "400px",
            background: "rgba(17, 17, 17, 0.95)",
            border: "1px solid rgba(255, 255, 255, 0.1)",
          }}
        >
          <div className="p-2.5">
            <div className="flex items-start gap-3">
              {/* Avatar placeholder */}
              {profileImageUrl ? (
                <img
                  src={profileImageUrl}
                  alt="User avatar"
                  className="size-8 select-none rounded-full"
                />
              ) : (
                <div className="flex-shrink-0">
                  <div className="size-8 select-none rounded-full bg-gradient-to-br from-pink-500 to-pink-600 flex items-center justify-center text-white font-medium">
                    U
                  </div>
                </div>
              )}

              {/* Input area */}
              <div className="flex-1">
                <textarea
                  ref={commentInputRef}
                  value={commentDraft}
                  onChange={(e) => setCommentDraft(e.target.value)}
                  placeholder="Start a new thread..."
                  className="w-full bg-transparent border-none outline-none text-white placeholder-gray-500 resize-none text-sm"
                  // style={{ minHeight: "60px", fontSize: "15px" }}
                  autoFocus
                  rows={2}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
                      e.preventDefault();
                      handleSubmitComment();
                    }
                    if (e.key === "Escape") {
                      handleCancelComment();
                    }
                  }}
                />
              </div>
            </div>
            {/* Bottom toolbar */}
            <div className="flex items-center justify-between mt-0">
              <div className="flex items-center gap-2">
                <button className="size-4 rounded hover:bg-neutral-800 text-neutral-400 flex items-center justify-center transition-all">
                  <PlusIcon className="size-4" />
                </button>
                <button className="size-4 rounded hover:bg-neutral-800 text-neutral-400 flex items-center justify-center transition-all">
                  <ImageIcon className="size-4" />
                </button>
                <div className="w-px h-5 bg-neutral-700 mx-1"></div>
                <button className="size-4 rounded hover:bg-neutral-800 text-neutral-400 flex items-center justify-center transition-all">
                  <TypeIcon className="size-4" />
                </button>
              </div>

              {/* Send button */}
              <button
                onClick={handleSubmitComment}
                disabled={!commentDraft.trim()}
                className={clsx(
                  "size-8 rounded-lg flex items-center justify-center transition-all bg-neutral-800",
                  commentDraft.trim()
                    ? "hover:bg-neutral-700"
                    : "text-neutral-500 cursor-not-allowed opacity-50"
                )}
              >
                <svg
                  width="24"
                  height="24"
                  viewBox="0 0 64 64"
                  className="size-3"
                  fill="none"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <defs>
                    <linearGradient
                      id="cmuxGradient"
                      x1="0%"
                      y1="0%"
                      x2="100%"
                      y2="0%"
                    >
                      <stop
                        offset="0%"
                        stopColor={commentDraft.trim() ? "#00D4FF" : "#666666"}
                      />
                      <stop
                        offset="100%"
                        stopColor={commentDraft.trim() ? "#7C3AED" : "#666666"}
                      />
                    </linearGradient>
                  </defs>
                  <polygon
                    fill="url(#cmuxGradient)"
                    points="0,0 68,32 0,64 0,48 40,32 0,16"
                  />
                </svg>
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Floating widget */}
      <div
        ref={widgetRef}
        data-cmux-comment-widget="true"
        className={`fixed z-[999999] rounded-2xl shadow-2xl backdrop-blur-md ${
          isOpen
            ? "opacity-100 scale-100"
            : "opacity-0 scale-95 pointer-events-none"
        }`}
        style={{
          left: 0,
          top: 0,
          transform: `translate(${position.x}px, ${position.y}px)`,
          width: "380px",
          background: "rgba(17, 17, 17, 0.95)",
          border: "1px solid rgba(255, 255, 255, 0.1)",
        }}
        onMouseDown={handleMouseDown}
      >
        {/* Header */}
        <div
          className="widget-header flex items-center justify-between pl-4 pr-2 py-2 cursor-move select-none border-b border-neutral-800"
          style={{ borderColor: "rgba(255, 255, 255, 0.1)" }}
        >
          <h3 className="text-base font-medium text-white select-none">
            Comments
          </h3>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setShowArchived(!showArchived)}
              className={clsx(
                "px-2 py-1 rounded text-xs transition-all",
                showArchived
                  ? "bg-neutral-700 text-white"
                  : "text-neutral-400 hover:bg-neutral-800"
              )}
              title={showArchived ? "Hide archived" : "Show archived"}
            >
              {showArchived ? "Hide" : "Show"} Archived
            </button>
            <button
              onClick={() => setIsOpen(false)}
              className="w-8 h-8 rounded-lg flex items-center justify-center text-neutral-400 hover:bg-neutral-800 transition-all"
            >
              ✕
            </button>
          </div>
        </div>

        {/* Content */}
        <div className="p-4 max-h-96 overflow-y-auto">
          <div className="space-y-3">
            {comments?.length === 0 ? (
              <p className="text-neutral-400 text-sm text-center py-8 select-none">
                No comments yet. Press "C" to add one.
              </p>
            ) : (
              comments?.map((comment: Comment) => (
                <div
                  key={comment._id}
                  className={clsx(
                    "flex items-start gap-3 group",
                    comment.archived && "opacity-60"
                  )}
                >
                  {comment.profileImageUrl ? (
                    <img
                      src={comment.profileImageUrl}
                      alt="User avatar"
                      className="w-8 h-8 rounded-full flex-shrink-0"
                    />
                  ) : (
                    <div className="w-8 h-8 rounded-full bg-gradient-to-br from-pink-500 to-pink-600 flex items-center justify-center text-white text-xs font-medium flex-shrink-0">
                      U
                    </div>
                  )}
                  <div className="flex-1">
                    <p className="text-sm text-white break-words">
                      {comment.content}
                    </p>
                    <div className="flex items-center gap-2 mt-1">
                      <p className="text-xs text-neutral-500">
                        {new Date(comment.createdAt).toLocaleString()}
                      </p>
                      {comment.archived && (
                        <span className="text-xs text-neutral-500 italic">
                          (Archived)
                        </span>
                      )}
                    </div>
                    {/* Always show replies */}
                    <div className="transform -translate-x-[40px]">
                      <CommentReplies
                        commentId={comment._id as Id<"comments">}
                      />
                    </div>
                  </div>
                  <button
                    onClick={() =>
                      archiveComment({
                        commentId: comment._id as Id<"comments">,
                        archived: !comment.archived,
                      })
                    }
                    className="opacity-0 group-hover:opacity-100 w-6 h-6 rounded flex items-center justify-center text-neutral-400 hover:bg-neutral-800 transition-all"
                    title={comment.archived ? "Unarchive" : "Archive"}
                  >
                    <ArchiveIcon />
                  </button>
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
          className="fixed bottom-4 right-4 w-14 h-14 bg-gradient-to-br from-pink-500 to-pink-600 rounded-full flex items-center justify-center text-white shadow-2xl transition-all z-[9999]"
        >
          <MessageIcon />
        </button>
      )}
    </>,
    document.body
  );
}
